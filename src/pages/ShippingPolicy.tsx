import { Truck, Clock, MapPin } from 'lucide-react'
import { useShippingSettings } from '../hooks/useShippingSettings'
import { formatBDT } from '../lib/constants'
import { useLanguage } from '../contexts/LanguageContext'

export default function ShippingPolicy() {
  const { settings, loading, refresh } = useShippingSettings()
  const { t, pick } = useLanguage()
  return (
    <div className="section-padding py-12 max-w-3xl mx-auto animate-fade-in">
      <h1 className="text-3xl font-serif text-ink-800 mb-8">Shipping & Delivery</h1>

      <div className="space-y-8">
        <section className="card p-6">
          <div className="flex items-center gap-3 mb-3">
            <div className="w-10 h-10 rounded-full bg-mink-100 flex items-center justify-center">
              <Truck size={20} className="text-ink-700" />
            </div>
            <h2 className="text-xl font-serif text-ink-800">Delivery Times</h2>
          </div>
          <ul className="space-y-2 text-sm text-ink-600">
            <li><strong>Inside Dhaka:</strong> 1–2 business days</li>
            <li><strong>Dhaka Suburbs:</strong> 2–3 business days</li>
            <li><strong>Outside Dhaka:</strong> 3–5 business days</li>
            <li>Orders placed after 5 PM will be processed the next business day.</li>
          </ul>
        </section>

        <section className="card p-6">
          <div className="flex items-center gap-3 mb-3">
            <div className="w-10 h-10 rounded-full bg-mink-100 flex items-center justify-center">
              <MapPin size={20} className="text-ink-700" />
            </div>
            <h2 className="text-xl font-serif text-ink-800">{pick('Shipping Costs', 'ডেলিভারি চার্জ')}</h2>
          </div>
          {loading ? <p className="text-sm text-ink-600">{t('common.loading')}</p> : settings ? (
            <ul className="space-y-2 text-sm text-ink-600">
              <li><strong>{pick('Chittagong / Chattogram district and city:', 'চট্টগ্রাম জেলা ও শহর:')}</strong> {formatBDT(settings.shipping_chattogram_rate)}</li>
              <li><strong>{pick('All other districts:', 'অন্য সব জেলা:')}</strong> {formatBDT(settings.shipping_default_rate)}</li>
              <li><strong>{pick('Free Shipping:', 'ফ্রি ডেলিভারি:')}</strong> {pick(`On orders of ${formatBDT(settings.free_shipping_threshold)} or more, before coupon discounts.`, `কুপনের ছাড়ের আগে ${formatBDT(settings.free_shipping_threshold)} বা তার বেশি অর্ডারে।`)}</li>
              <li>{pick('Valid free-shipping coupons also waive the delivery charge.', 'বৈধ ফ্রি ডেলিভারি কুপনেও ডেলিভারি চার্জ মওকুফ হয়।')}</li>
            </ul>
          ) : <div role="alert" className="text-sm text-red-600"><p>{t('checkout.shippingUnavailable')}</p><button onClick={() => { void refresh() }} className="mt-2 underline">{t('checkout.retryShipping')}</button></div>}
        </section>

        <section className="card p-6">
          <div className="flex items-center gap-3 mb-3">
            <div className="w-10 h-10 rounded-full bg-mink-100 flex items-center justify-center">
              <Clock size={20} className="text-ink-700" />
            </div>
            <h2 className="text-xl font-serif text-ink-800">Order Processing</h2>
          </div>
          <ul className="space-y-2 text-sm text-ink-600">
            <li>Orders are processed within 24 hours of placement.</li>
            <li>You will receive an SMS with your tracking number once your order is shipped.</li>
            <li>Delivery times may vary during holidays and promotional events.</li>
            <li>We deliver through trusted courier partners across all 64 districts of Bangladesh.</li>
          </ul>
        </section>

        <div className="bg-mink-50 rounded-2xl p-6 text-sm text-ink-600">
          <p>For any delivery-related questions, please contact us at <strong>hello@nuhani.com</strong> or call <strong>+880 1700 000000</strong>.</p>
        </div>
      </div>
    </div>
  )
}
