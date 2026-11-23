\set ON_ERROR_STOP on
\ir fixtures.sql
-- Cached subtotal100/total230 becomes live subtotal110/total240; shipping remains130.
UPDATE public.product_variants SET price = 110 WHERE id = '30000000-0000-0000-0000-000000000001';
CREATE TEMP TABLE before_total_mismatch AS SELECT
  (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.orders o) AS orders,
  (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.order_items i) AS items,
  (SELECT stock_quantity FROM public.product_variants WHERE id = '30000000-0000-0000-0000-000000000001') AS stock,
  (SELECT last_value FROM public.order_number_seq) AS sequence_value;
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Feni',1,NULL,'130',true,
  expected_total => '230',include_total_quote => true)$$,
  'Order total has changed. Please review your order.', 'changed subtotal with unchanged shipping requires review');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Feni',1,NULL,'130',true,
  expected_total => 'null',include_total_quote => true)$$,
  'Order total has changed. Please review your order.', 'null expected total rejected');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Feni',1,NULL,'130',true,
  expected_total => '"oops"',include_total_quote => true)$$,
  'Order total has changed. Please review your order.', 'malformed expected total rejected');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Feni',1,NULL,'130',true,
  expected_total => '240.001',include_total_quote => true)$$,
  'Order total has changed. Please review your order.', 'fractional changed expected total rejected');
SELECT pg_temp.assert_true((SELECT orders = (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.orders o)
  AND items = (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.order_items i)
  AND stock = (SELECT stock_quantity FROM public.product_variants WHERE id = '30000000-0000-0000-0000-000000000001')
  AND sequence_value = (SELECT last_value FROM public.order_number_seq) FROM before_total_mismatch),
  'total mismatches cause no orders/items/stock/sequence writes');
DO $$
DECLARE code text := 'TOTAL_FLAT';
BEGIN INSERT INTO public.coupons (code,type,value) VALUES (code,'flat',10); END;
$$;
-- Cached discount10 becomes live discount20, still shipping130.
UPDATE public.coupons SET value = 20 WHERE code = 'TOTAL_FLAT';
CREATE TEMP TABLE before_discount_mismatch AS SELECT
  (SELECT count(*) FROM public.orders) AS orders,
  (SELECT stock_quantity FROM public.product_variants WHERE id = '30000000-0000-0000-0000-000000000001') AS stock,
  (SELECT used_count FROM public.coupons WHERE code = 'TOTAL_FLAT') AS uses,
  (SELECT last_value FROM public.order_number_seq) AS sequence_value;
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Feni',1,'TOTAL_FLAT','130',true,
  expected_total => '230',include_total_quote => true)$$,
  'Order total has changed. Please review your order.', 'changed coupon discount with unchanged shipping requires review');
SELECT pg_temp.assert_true((SELECT orders = (SELECT count(*) FROM public.orders)
  AND stock = (SELECT stock_quantity FROM public.product_variants WHERE id = '30000000-0000-0000-0000-000000000001')
  AND uses = (SELECT used_count FROM public.coupons WHERE code = 'TOTAL_FLAT')
  AND sequence_value = (SELECT last_value FROM public.order_number_seq) FROM before_discount_mismatch),
  'discount mismatch causes no order/stock/coupon/sequence writes');
SELECT pg_temp.assert_true((pg_temp.checkout('Feni',1,'TOTAL_FLAT','130',true,
  expected_total => '220',include_total_quote => true)->>'total_amount')::numeric = 220, 'matching final total accepted after coupon');
SELECT pg_temp.assert_true((pg_temp.checkout('Feni',1,NULL,'130',true)->>'total_amount')::numeric = 240,
  'shipping-only quote remains backward compatible');
SELECT pg_temp.assert_true((pg_temp.checkout('Feni')->>'total_amount')::numeric = 240,
  'older clients lacking both quotes remain compatible');
ROLLBACK;
