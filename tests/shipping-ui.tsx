import React, { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import { HelmetProvider } from 'react-helmet-async'
import '../src/index.css'

// Real components and contexts; only the remote API is replaced. Never sends live requests.
const fixture = {
  settings: { id: '00000000-0000-0000-0000-000000000001', site_name: 'Nuhani test', phone: '', email: '', address: '', shipping_chattogram_rate: 70, shipping_default_rate: 130, free_shipping_threshold: 3000 },
  settingsError: false,
  saveError: false,
  emptySave: false,
  quoteChanged: false,
  stalePrice: false,
  couponChanged: false,
  delayedSave: false,
  delayedQuote: false,
  quotePending: false,
  writes: [] as { path: string; body: unknown }[],
}
;(window as unknown as { shippingTestFixture: typeof fixture }).shippingTestFixture = fixture
const nativeFetch = window.fetch.bind(window)
window.fetch = async (input, init) => {
  const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url, location.origin)
  if (url.origin === location.origin && !url.pathname.startsWith('/rest/v1/')) return nativeFetch(input, init)
  const path = url.pathname
  const method = init?.method ?? (input instanceof Request ? input.method : 'GET')
  const response = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } })
  if (path === '/rest/v1/rpc/get_public_settings') {
    return fixture.settingsError ? response({ message: 'Fixture: settings unavailable' }, 503) : response(fixture.settings)
  }
  if (path === '/rest/v1/site_settings') {
    if (method === 'PATCH') {
      const body = JSON.parse(String(init?.body ?? '{}'))
      fixture.writes.push({ path, body })
      if (fixture.delayedSave) await new Promise(resolve => setTimeout(resolve, 2000))
      if (fixture.saveError) return response({ message: 'Fixture: save denied' }, 403)
      if (fixture.emptySave) return response([])
      Object.assign(fixture.settings, body)
      return response({ id: fixture.settings.id })
    }
    return fixture.settingsError ? response({ message: 'Fixture: load failed' }, 503) : response([fixture.settings])
  }
  if (['/rest/v1/products', '/rest/v1/categories', '/rest/v1/banners'].includes(path)) return response([])
  if (path === '/rest/v1/coupons') return response([{ id: 'test-coupon', code: 'FREE', type: fixture.couponChanged ? 'flat' : 'free_shipping', value: fixture.couponChanged ? 100 : 0, min_order_amount: 0, is_active: true, max_uses: null, used_count: 0, expires_at: null }])
  if (path === '/rest/v1/rpc/get_order_quote') {
    fixture.quotePending = true
    if (fixture.delayedQuote) await new Promise(resolve => setTimeout(resolve, 2500))
    fixture.quotePending = false
    const body = JSON.parse(String(init?.body ?? '{}'))
    const cart = JSON.parse(localStorage.getItem('nuhani_cart') ?? '[]')
    const lines = body.p_items.map((item: { variant_id: string; quantity: number }) => {
      const price = fixture.stalePrice ? 2900 : cart.find((entry: { variant_id: string }) => entry.variant_id === item.variant_id).variant.price
      return { ...item, unit_price: price, total_price: Math.round(price * item.quantity * 100) / 100 }
    })
    const subtotal = lines.reduce((sum: number, line: { total_price: number }) => sum + line.total_price, 0)
    const discount = body.p_coupon_code && fixture.couponChanged ? 100 : 0
    const shipping = subtotal >= fixture.settings.free_shipping_threshold || body.p_coupon_code && !fixture.couponChanged ? 0 : ['chittagong', 'chattogram', 'চট্টগ্রাম'].includes(body.p_district.trim().toLowerCase()) ? fixture.settings.shipping_chattogram_rate : fixture.settings.shipping_default_rate
    return response({ subtotal, discount_amount: discount, shipping_amount: shipping, total_amount: subtotal - discount + shipping, items: lines })
  }
  if (path === '/rest/v1/rpc/place_order') {
    fixture.writes.push({ path, body: JSON.parse(String(init?.body ?? '{}')) })
    return response({ message: fixture.quoteChanged ? 'Shipping charge has changed. Please review your order.' : 'Fixture: order creation intentionally disabled' }, 409)
  }
  throw new Error(`Unexpected remote request blocked: ${method} ${path}`)
}

const [{ AuthProvider }, { CartProvider }, { ToastProvider }, { LanguageProvider }, { default: AdminSettings }, { default: Checkout }, { default: Cart }, { default: ShippingPolicy }, { default: Home }] = await Promise.all([
  import('../src/contexts/AuthContext'), import('../src/contexts/CartContext'), import('../src/contexts/ToastContext'), import('../src/contexts/LanguageContext'),
  import('../src/pages/admin/AdminSettings'), import('../src/pages/Checkout'), import('../src/pages/Cart'), import('../src/pages/ShippingPolicy'), import('../src/pages/Home'),
])

function Harness() {
  const [page, setPage] = useState('admin')
  const [revision, setRevision] = useState(0)
  const [subtotal, setSubtotal] = useState('1200')
  const [output, setOutput] = useState('')
  const resetCart = () => localStorage.setItem('nuhani_cart', JSON.stringify([{ variant_id: '00000000-0000-0000-0000-000000000002', quantity: 1, variant: { id: '00000000-0000-0000-0000-000000000002', price: Number(subtotal), size: 'M', color: 'Black', stock_quantity: 99, is_active: true, product: { id: 'test-product', name: 'Test Abaya', slug: 'test-abaya', images: [] } } }]))
  resetCart()
  return <>
    <div className="card p-4 m-4 flex flex-wrap gap-3 items-center">
      <label>Test page <select value={page} onChange={e => { setPage(e.target.value); setRevision(r => r + 1) }}><option value="admin">Admin</option><option value="checkout">Checkout</option><option value="cart">Cart</option><option value="policy">Shipping policy</option><option value="home">Home</option></select></label>
      <label>Test subtotal <input type="number" value={subtotal} onChange={e => setSubtotal(e.target.value)} /></label>
      <button onClick={() => { resetCart(); setRevision(r => r + 1) }}>Reload test page</button>
      <label><input type="checkbox" onChange={e => { fixture.settingsError = e.target.checked }} /> Simulate settings error</label>
      <label><input type="checkbox" onChange={e => { fixture.saveError = e.target.checked }} /> Simulate save error</label>
      <label><input type="checkbox" onChange={e => { fixture.emptySave = e.target.checked }} /> Simulate missing saved row</label>
      <label><input type="checkbox" onChange={e => { fixture.quoteChanged = e.target.checked }} /> Simulate server quote change</label>
      <label><input type="checkbox" onChange={e => { fixture.stalePrice = e.target.checked }} /> Simulate stale product price</label>
      <label><input type="checkbox" onChange={e => { fixture.couponChanged = e.target.checked }} /> Simulate coupon type change</label>
      <label><input type="checkbox" onChange={e => { fixture.delayedSave = e.target.checked }} /> Delay settings save</label>
      <label><input type="checkbox" onChange={e => { fixture.delayedQuote = e.target.checked }} /> Delay order quote</label>
      <button onClick={() => { fixture.settings.shipping_default_rate = 150 }}>Change default rate before submit</button>
      <button onClick={() => setOutput(JSON.stringify(fixture.writes))}>Inspect test requests</button>
    </div>
    <pre className="mx-4 whitespace-pre-wrap" aria-label="Test requests">{output}</pre>
    <HelmetProvider><LanguageProvider><ToastProvider><AuthProvider><CartProvider key={revision}>
      <MemoryRouter key={`${page}-${revision}`} initialEntries={[page === 'admin' ? '/admin/settings' : page === 'policy' ? '/shipping-policy' : `/${page}`]}>
        <Routes>
          <Route path="/admin/settings" element={<AdminSettings />} />
          <Route path="/checkout" element={<Checkout />} />
          <Route path="/cart" element={<Cart />} />
          <Route path="/shipping-policy" element={<ShippingPolicy />} />
          <Route path="/home" element={<Home />} />
          <Route path="*" element={<p>Test navigation complete</p>} />
        </Routes>
      </MemoryRouter>
    </CartProvider></AuthProvider></ToastProvider></LanguageProvider></HelmetProvider>
  </>
}
createRoot(document.getElementById('root')!).render(<Harness />)
