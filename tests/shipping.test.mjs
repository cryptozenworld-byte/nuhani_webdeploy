import assert from 'node:assert/strict'
import { test } from 'node:test'
import * as shipping from '../src/lib/constants.ts'
const { BD_DISTRICTS, getShippingCost } = shipping

const settings = { shipping_chattogram_rate: 70, shipping_default_rate: 130, free_shipping_threshold: 3000 }

test('Chittagong district and its aliases receive the local delivery rate', () => {
  for (const district of ['Chittagong', 'Chattogram', 'চট্টগ্রাম', ' chATTogram ']) {
    assert.equal(getShippingCost(district, settings, 1200), 70, district)
  }
})

test('every other selected district receives the default rate, including Chittagong division neighbors', () => {
  for (const { district } of BD_DISTRICTS.filter(({ district }) => district !== 'Chittagong')) {
    assert.equal(getShippingCost(district, settings, 1200), 130, district)
  }
})

test('free delivery starts at the configured pre-discount subtotal boundary', () => {
  assert.equal(getShippingCost('Dhaka', settings, 2999.99), 130)
  assert.equal(getShippingCost('Dhaka', settings, 3000), 0)
  assert.equal(getShippingCost('Chittagong', settings, 3001), 0)
})

test('decimal line prices at the free-delivery boundary do not add a shipping charge', () => {
  const subtotal = 682.8 * 3 + 951.6
  assert.equal(getShippingCost('Dhaka', settings, subtotal), 0)
})

test('admin changes affect both district rates and the free delivery threshold', () => {
  const updated = { shipping_chattogram_rate: 90, shipping_default_rate: 150, free_shipping_threshold: 4000 }
  assert.equal(getShippingCost('Chittagong', updated, 3000), 90)
  assert.equal(getShippingCost('Dhaka', updated, 3000), 150)
  assert.equal(getShippingCost('Dhaka', updated, 4000), 0)
})

test('a valid free-shipping coupon waives shipping below the threshold', () => {
  assert.equal(getShippingCost('Dhaka', settings, 500, true), 0)
  assert.equal(getShippingCost('Chittagong', settings, 500, true), 0)
})

test('an explicitly configured zero delivery rate remains zero', () => {
  assert.equal(getShippingCost('Dhaka', { ...settings, shipping_default_rate: 0 }, 500), 0)
})

test('server quotes preserve current line prices and exact monetary totals', () => {
  assert.equal(typeof shipping.getCheckoutQuote, 'function', 'quote validation is required')
  const items = [{ variant_id: 'a', quantity: 3 }, { variant_id: 'b', quantity: 1 }]
  const quote = { subtotal: 3000, discount_amount: 0, shipping_amount: 0, total_amount: 3000, items: [{ variant_id: 'a', quantity: 3, unit_price: 682.8, total_price: 2048.4 }, { variant_id: 'b', quantity: 1, unit_price: 951.6, total_price: 951.6 }] }
  assert.deepEqual(shipping.getCheckoutQuote(quote, items), quote)
  for (const invalid of [null, {}, { ...quote, subtotal: NaN }, { ...quote, total_amount: 3001 }, { ...quote, items: [] }, { ...quote, discount_amount: -1 }, { ...quote, shipping_amount: Infinity }, { ...quote, items: [{ ...quote.items[0], variant_id: 'wrong' }, quote.items[1]] }, { ...quote, items: [{ ...quote.items[0], quantity: 1 }, quote.items[1]] }, { ...quote, items: [{ ...quote.items[0], total_price: 1 }, quote.items[1]] }]) {
    assert.equal(shipping.getCheckoutQuote(invalid, items), null)
  }
})

test('server quote accepts updated prices and coupons instead of reusing a cached free-shipping estimate', () => {
  assert.equal(typeof shipping.getCheckoutQuote, 'function', 'quote validation is required')
  const items = [{ variant_id: 'a', quantity: 1 }]
  const quote = { subtotal: 2900, discount_amount: 100, shipping_amount: 130, total_amount: 2930, items: [{ variant_id: 'a', quantity: 1, unit_price: 2900, total_price: 2900 }] }
  assert.deepEqual(shipping.getCheckoutQuote(quote, items), quote)
})

test('public shipping settings reject missing, malformed, and out-of-range configuration', () => {
  assert.equal(typeof shipping.getShippingSettings, 'function', 'shipping configuration validation is required')
  for (const value of [null, {}, { ...settings, shipping_default_rate: -1 }, { ...settings, shipping_default_rate: NaN }, { ...settings, shipping_default_rate: Infinity }, { ...settings, shipping_default_rate: 1.5 }, { ...settings, shipping_default_rate: 1000001 }, { ...settings, free_shipping_threshold: 0 }, { ...settings, shipping_chattogram_rate: '70' }]) {
    assert.equal(shipping.getShippingSettings(value), null)
  }
  assert.deepEqual(shipping.getShippingSettings({ ...settings, telegram_bot_token: 'private' }), settings)
  assert.equal(shipping.getShippingSettings({ ...settings, shipping_default_rate: 0 }).shipping_default_rate, 0)
})

test('admin input parsing rejects blank and invalid values instead of saving them as zero', () => {
  assert.equal(typeof shipping.parseShippingSettings, 'function', 'shipping form validation is required')
  const draft = { shipping_chattogram_rate: '70', shipping_default_rate: '130', free_shipping_threshold: '3000' }
  assert.deepEqual(shipping.parseShippingSettings(draft), settings)
  for (const value of ['', ' ', '-1', '1.5', 'NaN', 'Infinity', '1000001', '0x80']) {
    assert.equal(shipping.parseShippingSettings({ ...draft, shipping_default_rate: value }), null, value)
  }
  assert.equal(shipping.parseShippingSettings({ ...draft, free_shipping_threshold: '0' }), null)
  assert.equal(shipping.parseShippingSettings({ ...draft, shipping_default_rate: '0' }).shipping_default_rate, 0)
})
