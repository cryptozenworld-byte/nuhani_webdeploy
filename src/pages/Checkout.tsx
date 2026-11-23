import { useEffect, useRef, useState } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { ChevronRight, Check, Shield, Lock } from 'lucide-react'
import { useCart } from '../contexts/CartContext'
import { useAuth } from '../contexts/AuthContext'
import { useToast } from '../contexts/ToastContext'
import { supabase } from '../lib/supabase'
import { formatBDT, BD_DISTRICTS, getShippingCost, getCheckoutQuote, type CheckoutQuote, PAYMENT_METHODS, districtName, divisionName } from '../lib/constants'
import { useShippingSettings } from '../hooks/useShippingSettings'
import { useLanguage } from '../contexts/LanguageContext'

const PAY_LABELS: Record<string, { nameKey: string; descKey: string }> = {
  bkash: { nameKey: 'checkout.payBkash', descKey: 'checkout.payBkashDesc' },
  card: { nameKey: 'checkout.payCard', descKey: 'checkout.payCardDesc' },
  cod: { nameKey: 'checkout.payCod', descKey: 'checkout.payCodDesc' },
}

export default function Checkout() {
  const { t, pick, lang } = useLanguage()
  const location = useLocation()
  const navigate = useNavigate()
  const { items, subtotal: cartSubtotal, clearCart } = useCart()
  const [quote, setQuote] = useState<CheckoutQuote | null>(null)
  const subtotal = quote?.subtotal ?? Math.round(cartSubtotal * 100) / 100
  const { session } = useAuth()
  const { showToast } = useToast()

  const discount = quote?.discount_amount ?? (location.state as { discount?: number })?.discount ?? 0
  const couponCode = (location.state as { couponCode?: string })?.couponCode ?? null
  const freeShipping = !!couponCode && (location.state as { freeShipping?: boolean })?.freeShipping === true
  const { settings: shippingSettings, loading: shippingLoading, error: shippingError, refresh: refreshShipping } = useShippingSettings()
  const [shippingNotice, setShippingNotice] = useState('')
  const quoteRequest = useRef(0)

  const [step, setStep] = useState<'shipping' | 'payment' | 'review'>('shipping')
  const [processing, setProcessing] = useState(false)
  const [shippingInfo, setShippingInfo] = useState({
    full_name: '',
    phone: '',
    email: '',
    address_line1: '',
    address_line2: '',
    city: '',
    district: 'Dhaka',
    division: 'Dhaka',
    postal_code: '',
    notes: '',
  })
  const [paymentMethod, setPaymentMethod] = useState<'bkash' | 'nagad' | 'card' | 'cod'>('cod')

  useEffect(() => {
    setQuote(null)
    setShippingNotice('')
    setProcessing(false)
    return () => { quoteRequest.current++ }
  }, [items, shippingInfo, couponCode, paymentMethod])

  const shippingCost = shippingSettings ? quote?.shipping_amount ?? getShippingCost(shippingInfo.district, shippingSettings, subtotal, freeShipping) : null
  const total = shippingCost === null ? null : quote?.total_amount ?? Math.round((subtotal - discount + shippingCost) * 100) / 100

  const fetchOrderQuote = async () => {
    const requestedItems = items.map(({ variant_id, quantity }) => ({ variant_id, quantity }))
    const { data, error } = await supabase.rpc('get_order_quote', {
      p_items: requestedItems,
      p_district: shippingInfo.district,
      p_coupon_code: couponCode,
    })
    if (error) throw error
    const currentQuote = getCheckoutQuote(data, requestedItems)
    if (!currentQuote) throw new Error(t('checkout.shippingUnavailable'))
    return currentQuote
  }

  const validateShipping = () => {
    const fieldLabels: Record<string, string> = {
      full_name: t('checkout.fullName'),
      phone: t('checkout.phone'),
      address_line1: t('checkout.addressLine1'),
      city: t('checkout.city'),
      district: t('checkout.district'),
    }
    const required = ['full_name', 'phone', 'address_line1', 'city', 'district']
    for (const field of required) {
      if (!shippingInfo[field as keyof typeof shippingInfo].trim()) {
        showToast(t('checkout.fillIn', { field: fieldLabels[field] ?? field }), 'error')
        return false
      }
    }
    if (!session && !shippingInfo.email.trim()) {
      showToast(t('checkout.emailRequired'), 'error')
      return false
    }
    return true
  }

  const handlePlaceOrder = async () => {
    if (processing || shippingLoading) return
    if (shippingCost === null) {
      showToast(t('checkout.shippingUnavailable'), 'error')
      return
    }
    if (!validateShipping()) return
    if (items.length === 0) {
      showToast('Your cart is empty', 'error')
      return
    }

    const currentRequest = ++quoteRequest.current
    setProcessing(true)
    setShippingNotice('')
    try {
      const currentSettings = await refreshShipping()
      if (currentRequest !== quoteRequest.current) return
      if (!currentSettings) {
        showToast(t('checkout.shippingUnavailable'), 'error')
        return
      }
      const currentQuote = await fetchOrderQuote()
      if (currentRequest !== quoteRequest.current) return
      const linePricesChanged = currentQuote.items.some((line, i) => line.unit_price !== (quote?.items[i]?.unit_price ?? items[i].variant?.price))
      if (currentQuote.shipping_amount !== shippingCost || currentQuote.subtotal !== subtotal || currentQuote.discount_amount !== discount || currentQuote.total_amount !== total || linePricesChanged) {
        setQuote(currentQuote)
        setShippingNotice(t('checkout.shippingChanged'))
        return
      }
      // Server-authoritative order creation: pricing, stock, coupon and totals
      // are all validated/computed inside the place_order() database function.
      const rpcItems = items.map((item) => ({
        variant_id: item.variant_id,
        quantity: item.quantity,
      }))

      const { data: order, error: orderError } = await supabase.rpc('place_order', {
        p_items: rpcItems,
        p_shipping: {
          full_name: shippingInfo.full_name,
          phone: shippingInfo.phone,
          email: shippingInfo.email || null,
          address_line1: shippingInfo.address_line1,
          address_line2: shippingInfo.address_line2 || null,
          city: shippingInfo.city,
          district: shippingInfo.district,
          division: shippingInfo.division,
          postal_code: shippingInfo.postal_code || null,
          expected_shipping_amount: currentQuote.shipping_amount,
          expected_total_amount: currentQuote.total_amount,
        },
        p_payment_method: paymentMethod,
        p_coupon_code: couponCode,
        p_notes: shippingInfo.notes || null,
      })

      if (orderError) throw orderError

      // Remember the phone so the guest confirmation page can look the order up
      // after the payment-gateway redirect (orders are not publicly readable).
      sessionStorage.setItem('nuhani_order_phone', shippingInfo.phone)

      // Telegram "New Order Received" notification is now sent by a DB trigger
      // (reliable — fires on order insert inside PostgreSQL, no browser dependency).
      // See supabase/migrations/20261121000000_reliable_telegram_order_notify.sql

      await clearCart()

      // For online payments, create payment session and redirect
      if (paymentMethod !== 'cod') {
        const { data: payData, error: payError } = await supabase.functions.invoke('payment-gateway', {
          body: JSON.stringify({
            action: 'create_payment',
            order_id: order.id,
            payment_method: paymentMethod,
            order_number: order.order_number,
          }),
        })

        if (payError || payData?.error) {
          showToast(payData?.error ?? t('checkout.gatewayError'), 'error')
          navigate(`/order-confirmation/${order.order_number}`)
          return
        }

        // Redirect to payment gateway
        if (payData?.payment_url) {
          window.location.href = payData.payment_url
          return
        }

        // If no URL (gateway not configured), go to confirmation with pending payment
        showToast(t('checkout.gatewayNotConfigured'), 'info')
      }

      navigate(`/order-confirmation/${order.order_number}`)
    } catch (err) {
      if (currentRequest !== quoteRequest.current) return
      const msg = err && typeof err === 'object' && 'message' in err && typeof err.message === 'string' ? err.message : t('checkout.failedToPlace')
      if (msg.includes('Shipping charge has changed') || msg.includes('Order total has changed')) {
        await refreshShipping()
        if (currentRequest !== quoteRequest.current) return
        try {
          const nextQuote = await fetchOrderQuote()
          if (currentRequest !== quoteRequest.current) return
          setQuote(nextQuote)
        } catch {
          if (currentRequest !== quoteRequest.current) return
          setQuote(null)
        }
        setShippingNotice(t('checkout.shippingChanged'))
      } else {
        showToast(msg, 'error')
      }
    } finally {
      if (currentRequest === quoteRequest.current) setProcessing(false)
    }
  }

  if (items.length === 0) {
    return (
      <div className="section-padding py-20 text-center">
        <h1 className="text-2xl font-serif text-ink-800 mb-4">{t('cart.empty')}</h1>
        <button onClick={() => navigate('/shop')} className="btn-primary">{t('cart.startShopping')}</button>
      </div>
    )
  }

  return (
    <div className="section-padding py-8 animate-fade-in">
      <h1 className="text-3xl font-serif text-ink-800 mb-8">{t('checkout.title')}</h1>

      {/* Steps */}
      <div className="flex items-center gap-2 mb-8 text-sm">
        {[
          { key: 'shipping', label: t('checkout.shipping') },
          { key: 'payment', label: t('checkout.payment') },
          { key: 'review', label: t('checkout.review') },
        ].map((s, i) => (
          <div key={s.key} className="flex items-center gap-2">
            <div
              className={`w-7 h-7 rounded-full flex items-center justify-center text-xs font-medium ${
                step === s.key || (['shipping', 'payment', 'review'].indexOf(step) > i)
                  ? 'bg-ink-700 text-ivory-50'
                  : 'bg-ivory-200 text-ink-400'
              }`}
            >
              {['shipping', 'payment', 'review'].indexOf(step) > i ? <Check size={14} /> : i + 1}
            </div>
            <span className={step === s.key ? 'text-ink-700 font-medium' : 'text-ink-400'}>{s.label}</span>
            {i < 2 && <ChevronRight size={14} className="text-ink-300" />}
          </div>
        ))}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
        <div className="lg:col-span-2">
          {/* Step 1: Shipping */}
          {step === 'shipping' && (
            <div className="card p-6 animate-fade-in">
              <h2 className="text-xl font-serif text-ink-800 mb-4">{t('checkout.shippingAddress')}</h2>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label className="text-sm text-ink-600 mb-1.5 block">{t('checkout.fullName')} *</label>
                  <input
                    type="text"
                    aria-label={t('checkout.fullName')}
                    value={shippingInfo.full_name}
                    onChange={(e) => setShippingInfo({ ...shippingInfo, full_name: e.target.value })}
                    className="input-field"
                    required
                  />
                </div>
                <div>
                  <label className="text-sm text-ink-600 mb-1.5 block">{t('checkout.phone')} *</label>
                  <input
                    type="tel"
                    value={shippingInfo.phone}
                    onChange={(e) => setShippingInfo({ ...shippingInfo, phone: e.target.value })}
                    className="input-field"
                    placeholder="01XXXXXXXXX"
                    required
                  />
                </div>
                {!session && (
                  <div className="md:col-span-2">
                    <label className="text-sm text-ink-600 mb-1.5 block">{t('checkout.email')} *</label>
                    <input
                      type="email"
                      aria-label={t('checkout.email')}
                      value={shippingInfo.email}
                      onChange={(e) => setShippingInfo({ ...shippingInfo, email: e.target.value })}
                      className="input-field"
                      required
                    />
                  </div>
                )}
                <div className="md:col-span-2">
                  <label className="text-sm text-ink-600 mb-1.5 block">{t('checkout.addressLine1')} *</label>
                  <input
                    type="text"
                    value={shippingInfo.address_line1}
                    onChange={(e) => setShippingInfo({ ...shippingInfo, address_line1: e.target.value })}
                    className="input-field"
                    placeholder={t('checkout.addressPlaceholder')}
                    required
                  />
                </div>
                <div className="md:col-span-2">
                  <label className="text-sm text-ink-600 mb-1.5 block">{t('checkout.addressLine2')}</label>
                  <input
                    type="text"
                    value={shippingInfo.address_line2}
                    onChange={(e) => setShippingInfo({ ...shippingInfo, address_line2: e.target.value })}
                    className="input-field"
                    placeholder={t('checkout.address2Placeholder')}
                  />
                </div>
                <div>
                  <label className="text-sm text-ink-600 mb-1.5 block">{t('checkout.city')} *</label>
                  <input
                    type="text"
                    aria-label={t('checkout.city')}
                    value={shippingInfo.city}
                    onChange={(e) => setShippingInfo({ ...shippingInfo, city: e.target.value })}
                    className="input-field"
                    required
                  />
                </div>
                <div>
                  <label className="text-sm text-ink-600 mb-1.5 block">{t('checkout.district')} *</label>
                  <select
                    value={shippingInfo.district}
                    onChange={(e) => {
                      const dist = BD_DISTRICTS.find((d) => d.district === e.target.value)
                      setShippingInfo({
                        ...shippingInfo,
                        district: e.target.value,
                        division: dist?.division ?? shippingInfo.division,
                      })
                    }}
                    className="input-field"
                  >
                    {BD_DISTRICTS.map((d) => (
                      <option key={d.district} value={d.district}>{districtName(d.district, lang)}</option>
                    ))}
                  </select>
                </div>
                <div>
                  <label className="text-sm text-ink-600 mb-1.5 block">{t('checkout.postalCode')}</label>
                  <input
                    type="text"
                    value={shippingInfo.postal_code}
                    onChange={(e) => setShippingInfo({ ...shippingInfo, postal_code: e.target.value })}
                    className="input-field"
                  />
                </div>
                <div>
                  <label className="text-sm text-ink-600 mb-1.5 block">{t('checkout.division')}</label>
                  <input
                    type="text"
                    value={divisionName(shippingInfo.division, lang)}
                    disabled
                    className="input-field opacity-60"
                  />
                </div>
                <div className="md:col-span-2">
                  <label className="text-sm text-ink-600 mb-1.5 block">{t('checkout.orderNotes')}</label>
                  <textarea
                    value={shippingInfo.notes}
                    onChange={(e) => setShippingInfo({ ...shippingInfo, notes: e.target.value })}
                    className="input-field min-h-20 resize-none"
                    placeholder={t('checkout.notesPlaceholder')}
                  />
                </div>
              </div>
              <button
                onClick={() => validateShipping() && setStep('payment')}
                className="btn-primary w-full mt-6"
              >
                {t('checkout.continueToPayment')}
              </button>
            </div>
          )}

          {/* Step 2: Payment */}
          {step === 'payment' && (
            <div className="card p-6 animate-fade-in">
              <h2 className="text-xl font-serif text-ink-800 mb-4">{t('checkout.paymentMethod')}</h2>
              <div className="space-y-3">
                {PAYMENT_METHODS.map((method) => (
                  <button
                    key={method.id}
                    onClick={() => setPaymentMethod(method.id)}
                    className={`w-full flex items-center gap-4 p-4 rounded-2xl border-2 transition-all text-left ${
                      paymentMethod === method.id
                        ? 'border-ink-700 bg-mink-50'
                        : 'border-stone-300 hover:border-mink-200'
                    }`}
                  >
                    <span className="text-2xl">{method.icon}</span>
                    <div className="flex-1">
                      <h4 className="font-medium text-ink-800">{t(PAY_LABELS[method.id]?.nameKey ?? 'checkout.paymentMethod')}</h4>
                      <p className="text-sm text-ink-400">{t(PAY_LABELS[method.id]?.descKey ?? '')}</p>
                    </div>
                    <div
                      className={`w-5 h-5 rounded-full border-2 flex items-center justify-center ${
                        paymentMethod === method.id ? 'border-ink-700 bg-ink-700' : 'border-stone-300'
                      }`}
                    >
                      {paymentMethod === method.id && <Check size={12} className="text-ivory-50" />}
                    </div>
                  </button>
                ))}
              </div>

              {paymentMethod === 'cod' && (
                <div className="bg-amber-50 border border-amber-200 rounded-2xl p-4 mt-4 text-sm text-amber-700">
                  <p className="font-medium mb-1">{t('checkout.payCod')}</p>
                  <p>{t('checkout.payCodNote')}</p>
                </div>
              )}

              {paymentMethod !== 'cod' && (
                <div className="bg-ivory-100 rounded-2xl p-4 mt-4 text-sm text-ink-500 flex items-start gap-2">
                  <Lock size={16} className="text-ink-400 shrink-0 mt-0.5" />
                  <div>
                    <p className="font-medium text-ink-700">{t('checkout.securePayment')}</p>
                    <p className="mt-0.5">{t('checkout.securePaymentDesc', { name: t(PAY_LABELS[paymentMethod]?.nameKey ?? 'checkout.paymentMethod') })}</p>
                  </div>
                </div>
              )}

              <div className="flex gap-3 mt-6">
                <button onClick={() => setStep('shipping')} className="btn-outline flex-1">{t('common.back')}</button>
                <button onClick={() => setStep('review')} className="btn-primary flex-1">{t('checkout.reviewOrder')}</button>
              </div>
            </div>
          )}

          {/* Step 3: Review */}
          {step === 'review' && (
            <div className="card p-6 animate-fade-in">
              <h2 className="text-xl font-serif text-ink-800 mb-4">{t('checkout.reviewYourOrder')}</h2>

              <div className="mb-6">
                <h4 className="text-sm font-medium text-ink-700 mb-2">{t('checkout.shippingTo')}</h4>
                <div className="text-sm text-ink-500 bg-ivory-100 rounded-2xl p-4">
                  <p className="font-medium text-ink-700">{shippingInfo.full_name}</p>
                  <p>{shippingInfo.address_line1}</p>
                  {shippingInfo.address_line2 && <p>{shippingInfo.address_line2}</p>}
                  <p>{shippingInfo.city}, {districtName(shippingInfo.district, lang)}</p>
                  <p>{shippingInfo.phone}</p>
                </div>
              </div>

              <div className="mb-6">
                <h4 className="text-sm font-medium text-ink-700 mb-2">{t('checkout.paymentMethod')}</h4>
                <div className="text-sm text-ink-500 bg-ivory-100 rounded-2xl p-4 flex items-center gap-2">
                  <Shield size={16} className="text-ink-400" />
                  {t(PAY_LABELS[paymentMethod]?.nameKey ?? 'checkout.paymentMethod')}
                  {paymentMethod === 'cod' && <span className="text-xs text-amber-600">{t('checkout.verificationNote')}</span>}
                </div>
              </div>

              <div className="mb-6">
                <h4 className="text-sm font-medium text-ink-700 mb-2">{t('checkout.items')}</h4>
                <div className="space-y-2">
                  {items.map((item, i) => {
                    const variant = 'variant' in item ? item.variant : undefined
                    const variantLabel = [variant?.size?.trim(), variant?.color?.trim()].filter(Boolean).join(' · ')
                    return (
                      <div key={(item as { id?: string }).id ?? item.variant_id} className="flex justify-between text-sm">
                        <span className="text-ink-600">
                          {pick(variant?.product?.name, variant?.product?.name_bn) || t('common.product')} × {item.quantity}
                          {variantLabel && ` (${variantLabel})`}
                        </span>
                        <span className="text-ink-700 font-medium">
                          {formatBDT(quote?.items[i]?.total_price ?? (variant?.price ?? 0) * item.quantity)}
                        </span>
                      </div>
                    )
                  })}
                </div>
              </div>

              <div className="flex gap-3">
                <button onClick={() => setStep('payment')} disabled={processing} className="btn-outline flex-1">{t('common.back')}</button>
                <button
                  onClick={handlePlaceOrder}
                  disabled={processing || shippingLoading || shippingCost === null}
                  className="btn-primary flex-1 flex items-center justify-center gap-2"
                >
                  {processing ? (
                    <>
                      <div className="w-5 h-5 border-2 border-ivory-50 border-t-transparent rounded-full animate-spin" />
                      {paymentMethod === 'cod' ? t('checkout.placingOrder') : t('checkout.redirecting')}
                    </>
                  ) : (
                    total === null ? t('common.loading') : paymentMethod === 'cod' ? t('checkout.placeOrderWith', { price: formatBDT(total) }) : t('checkout.payWith', { price: formatBDT(total) })
                  )}
                </button>
              </div>
            </div>
          )}
        </div>

        {/* Summary */}
        <div className="lg:col-span-1">
          <div className="card p-6 sticky top-24">
            <h2 className="text-lg font-serif text-ink-800 mb-4">{t('checkout.orderSummary')}</h2>
            <div className="space-y-2 text-sm">
              <div className="flex justify-between text-ink-600">
                <span>{t('checkout.subtotalItems', { n: items.length })}</span>
                <span>{formatBDT(subtotal)}</span>
              </div>
              {discount > 0 && (
                <div className="flex justify-between text-green-600">
                  <span>{t('checkout.discount')}</span>
                  <span>-{formatBDT(discount)}</span>
                </div>
              )}
              <div className="flex justify-between text-ink-600">
                <span>{t('cart.shipping')}</span>
                <span>{shippingLoading ? t('common.loading') : shippingCost === null ? '—' : shippingCost === 0 ? t('checkout.free') : formatBDT(shippingCost)}</span>
              </div>
            </div>
            <div className="flex justify-between text-lg font-semibold text-ink-800 border-t border-stone-200 pt-4 mt-4">
              <span>{t('cart.total')}</span>
              <span>{shippingLoading ? t('common.loading') : total === null ? '—' : formatBDT(total)}</span>
            </div>
            {shippingError && <div role="alert" className="mt-4 text-sm text-red-600"><p>{t('checkout.shippingUnavailable')}</p><button onClick={() => { void refreshShipping() }} className="mt-2 underline">{t('checkout.retryShipping')}</button></div>}
            {shippingNotice && <p role="alert" className="mt-4 text-sm text-amber-700">{shippingNotice}</p>}
          </div>
        </div>
      </div>
    </div>
  )
}
