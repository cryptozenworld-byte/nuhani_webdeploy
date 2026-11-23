\set ON_ERROR_STOP on
\ir fixtures.sql
DO $$
DECLARE district text; result jsonb;
BEGIN
  FOREACH district IN ARRAY ARRAY['Chattogram', 'chattogram', ' CHITTAGONG ', 'Chittagong', 'চট্টগ্রাম', '  চট্টগ্রাম  ', E'\tChAtToGrAm\n'] LOOP
    result := pg_temp.checkout(district);
    PERFORM pg_temp.assert_true((result->>'shipping_amount')::numeric = 70, 'Chattogram alias: ' || district);
  END LOOP;
  FOREACH district IN ARRAY ARRAY['Dhaka', 'Feni', 'Comilla', 'CoxsBazar', 'Cox''s Bazar', 'Sylhet', 'Unknown'] LOOP
    result := pg_temp.checkout(district);
    PERFORM pg_temp.assert_true((result->>'shipping_amount')::numeric = 130, 'default district, no city/division override: ' || district);
  END LOOP;
  result := pg_temp.checkout('Chattogram', city => 'Dhaka', division => 'Dhaka');
  PERFORM pg_temp.assert_true((result->>'shipping_amount')::numeric = 70, 'district controls rate regardless of city/division');
END;
$$;
SELECT pg_temp.assert_true((SELECT shipping_chattogram_rate = 70 AND shipping_default_rate = 130 AND free_shipping_threshold = 3000
  FROM public.site_settings), 'default settings contract');
-- Preserve the entire latest original whitelist, while secrets never appear.
SELECT pg_temp.assert_true((SELECT array_agg(key ORDER BY key) = ARRAY[
  'about_hero_image_url','address','courier_provider','email','facebook_url','free_shipping_threshold',
  'hero_image_url','hero_mobile_image_url','instagram_url','logo_url','phone','shipping_chattogram_rate',
  'shipping_default_rate','site_name','story_image_url','telegram_bot_username','twitter_url','whatsapp_number','youtube_url']
  FROM jsonb_object_keys(public.get_public_settings()) AS keys(key)), 'exact public whitelist: all 16 original plus 3 shipping fields');
SELECT pg_temp.assert_true(NOT (public.get_public_settings() ?| ARRAY['telegram_bot_token','telegram_chat_id','pathao_api_key',
  'steadfast_api_key','sslcommerz_store_password','bkash_app_secret','nagad_api_key']), 'no secrets exposed');
UPDATE public.product_variants SET price = 1499.99 WHERE id = '30000000-0000-0000-0000-000000000001';
SELECT pg_temp.assert_true((pg_temp.checkout('Dhaka', 2)->>'shipping_amount')::numeric = 130, 'subtotal just below threshold pays shipping');
UPDATE public.product_variants SET price = 1500 WHERE id = '30000000-0000-0000-0000-000000000001';
SELECT pg_temp.assert_true((pg_temp.checkout('Dhaka', 2)->>'shipping_amount')::numeric = 0, 'subtotal exactly threshold gets free shipping');
DO $$
DECLARE percent_code text := 'TEST_PERCENT'; flat_code text := 'TEST_FLAT'; free_code text := 'TEST_FREE';
  expired_code text := 'TEST_EXPIRED'; inactive_code text := 'TEST_INACTIVE'; max_code text := 'TEST_MAX'; minimum_code text := 'TEST_MIN';
BEGIN
  INSERT INTO public.coupons (code, type, value) VALUES (percent_code, 'percentage', 50), (flat_code, 'flat', 200), (free_code, 'free_shipping', 0);
  INSERT INTO public.coupons (code, type, value, expires_at) VALUES (expired_code, 'free_shipping', 0, now() - interval '1 day');
  INSERT INTO public.coupons (code, type, value, is_active) VALUES (inactive_code, 'free_shipping', 0, false);
  INSERT INTO public.coupons (code, type, value, max_uses, used_count) VALUES (max_code, 'free_shipping', 0, 1, 1);
  INSERT INTO public.coupons (code, type, value, min_order_amount) VALUES (minimum_code, 'free_shipping', 0, 9000);
END;
$$;
SELECT pg_temp.assert_true((pg_temp.checkout('Dhaka', 2, 'TEST_PERCENT')->>'shipping_amount')::numeric = 0,
  'free shipping threshold uses PRE-discount subtotal');
SELECT pg_temp.assert_true((pg_temp.checkout('Dhaka', 1, 'TEST_FLAT')->>'total_amount')::numeric = 1430, 'flat discount and shipping preserved');
SELECT pg_temp.assert_true((pg_temp.checkout('Dhaka', 1, ' test_free ', '0', true)->>'shipping_amount')::numeric = 0,
  'valid free-shipping coupon applied before quote check');
SELECT pg_temp.assert_true((SELECT used_count = 1 FROM public.coupons WHERE code = 'TEST_FREE'), 'valid coupon usage increments once');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Dhaka', 1, 'TEST_EXPIRED')$$, 'expired', 'expired coupon rejected');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Dhaka', 1, 'TEST_INACTIVE')$$, 'no longer active', 'inactive coupon rejected');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Dhaka', 1, 'TEST_MAX')$$, 'usage limit', 'exhausted coupon rejected');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Dhaka', 1, 'TEST_MIN')$$, 'minimum order', 'minimum coupon subtotal enforced');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Dhaka', 1, 'UNKNOWN')$$, 'Invalid coupon', 'unknown coupon rejected');
-- Snapshot order, inventory, coupon usage AND sequence; rejection must happen before order INSERT.
CREATE TEMP TABLE before_mismatch AS SELECT
  (SELECT count(*) FROM public.orders) AS orders, (SELECT count(*) FROM public.order_items) AS items,
  (SELECT stock_quantity FROM public.product_variants WHERE id = '30000000-0000-0000-0000-000000000001') AS stock,
  (SELECT used_count FROM public.coupons WHERE code = 'TEST_FREE') AS uses,
  (SELECT last_value FROM public.order_number_seq) AS sequence_value;
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Dhaka', 1, NULL, '1', true)$$,
  'Shipping charge has changed. Please review your order.', 'stale quote rejected with clear message');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Dhaka', 1, 'TEST_FREE', '130', true)$$,
  'Shipping charge has changed. Please review your order.', 'quote comparison is AFTER coupon');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Dhaka', 1, NULL, 'null', true)$$,
  'Shipping charge has changed. Please review your order.', 'null quote rejected');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Dhaka', 1, NULL, '"oops"', true)$$,
  'Shipping charge has changed. Please review your order.', 'malformed quote rejected');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Dhaka', 1, NULL, '130.5', true)$$,
  'Shipping charge has changed. Please review your order.', 'fractional quote rejected');
SELECT pg_temp.assert_true((SELECT orders = (SELECT count(*) FROM public.orders) AND items = (SELECT count(*) FROM public.order_items)
  AND stock = (SELECT stock_quantity FROM public.product_variants WHERE id = '30000000-0000-0000-0000-000000000001')
  AND uses = (SELECT used_count FROM public.coupons WHERE code = 'TEST_FREE')
  AND sequence_value = (SELECT last_value FROM public.order_number_seq) FROM before_mismatch),
  'quote mismatch causes no order/items/stock/coupon/sequence writes');
SELECT pg_temp.assert_true((pg_temp.checkout('Dhaka', 1, NULL, '130', true)->>'shipping_amount')::numeric = 130, 'correct quoted shipping accepted');
DO $$
DECLARE stock_before integer; order_result jsonb;
BEGIN
  SELECT stock_quantity INTO stock_before FROM public.product_variants WHERE id = '30000000-0000-0000-0000-000000000001';
  order_result := pg_temp.checkout('Dhaka', 2, 'TEST_PERCENT', '0', true);
  PERFORM pg_temp.assert_true((order_result->>'discount_amount')::numeric = 1500
    AND (order_result->>'total_amount')::numeric = 1500, 'percentage coupon pricing preserved');
  PERFORM pg_temp.assert_true((SELECT stock_quantity = stock_before - 2 FROM public.product_variants
    WHERE id = '30000000-0000-0000-0000-000000000001'), 'successful checkout decrements exact quantity');
END;
$$;
-- Existing snapshots remain unchanged after configuration changes.
CREATE TEMP TABLE orders_before_config AS SELECT id, to_jsonb(o) AS snapshot FROM public.orders o;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
SET LOCAL ROLE authenticated;
UPDATE public.site_settings SET shipping_chattogram_rate = 85, shipping_default_rate = 145, free_shipping_threshold = 4000;
SELECT pg_temp.assert_true((public.get_public_settings()->>'shipping_chattogram_rate')::numeric = 85, 'admin rate change immediately public');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT pg_temp.assert_true((pg_temp.checkout(' ChItTaGoNg ')->>'shipping_amount')::numeric = 85, 'updated Chattogram rate used');
SELECT pg_temp.assert_true((pg_temp.checkout('Feni')->>'shipping_amount')::numeric = 145, 'updated default rate used');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Feni', 1, NULL, '130', true)$$,
  'Shipping charge has changed. Please review your order.', 'admin rate change invalidates previous checkout quote');
SELECT pg_temp.assert_true((pg_temp.checkout('Dhaka', 2)->>'shipping_amount')::numeric = 145, 'updated threshold used');
SELECT pg_temp.assert_true((pg_temp.checkout('Dhaka', 3)->>'shipping_amount')::numeric = 0, 'above updated threshold ships free');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM orders_before_config b JOIN public.orders o USING (id) WHERE b.snapshot <> to_jsonb(o)),
  'existing orders unchanged by configuration updates');
SELECT pg_temp.assert_true(EXISTS (SELECT 1 FROM public.order_items WHERE product_name = 'Test product'
  AND variant_details = '{"size":"M","color":"Blue"}'::jsonb AND unit_price = 1500), 'order line snapshots preserved');
SELECT pg_temp.assert_true(EXISTS (SELECT 1 FROM public.orders WHERE notes = 'Test notes' AND guest_email = 'fixture@example.invalid'),
  'guest fields and notes preserved');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Dhaka', 0)$$, 'Invalid quantity', 'invalid quantity rejected');
UPDATE public.product_variants SET stock_quantity = 0 WHERE id = '30000000-0000-0000-0000-000000000001';
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Dhaka')$$, 'Insufficient stock', 'stock validation preserved');
UPDATE public.product_variants SET stock_quantity = 100 WHERE id = '30000000-0000-0000-0000-000000000001';
-- Whole taka with no implicit fractional rounding, non-null, bounded values.
SELECT pg_temp.expect_error($$UPDATE public.site_settings SET shipping_chattogram_rate = -1$$, 'check constraint', 'negative rate rejected');
SELECT pg_temp.expect_error($$UPDATE public.site_settings SET shipping_default_rate = 130.5$$, 'check constraint', 'fractional taka rejected');
SELECT pg_temp.expect_error($$UPDATE public.site_settings SET free_shipping_threshold = 0$$, 'check constraint', 'nonpositive threshold rejected');
SELECT pg_temp.expect_error($$UPDATE public.site_settings SET shipping_default_rate = 1000001$$, 'check constraint', 'excessive rate rejected');
SELECT pg_temp.expect_error($$UPDATE public.site_settings SET free_shipping_threshold = 1000001$$, 'check constraint', 'excessive threshold rejected');
SELECT pg_temp.expect_error($$UPDATE public.site_settings SET shipping_chattogram_rate = NULL$$, 'not-null constraint', 'null rate rejected');
SELECT pg_temp.expect_error($$UPDATE public.site_settings SET free_shipping_threshold = 3000.5$$, 'check constraint', 'fractional threshold rejected');
SELECT pg_temp.expect_error($$UPDATE public.site_settings SET shipping_default_rate = 'NaN'::numeric$$, 'check constraint', 'NaN rejected');
UPDATE public.site_settings SET shipping_chattogram_rate = 0, shipping_default_rate = 1000000, free_shipping_threshold = 1000000;
SELECT pg_temp.assert_true((pg_temp.checkout('Chattogram')->>'shipping_amount')::numeric = 0, 'zero rate allowed');
-- Auth/customer cannot read credentials or write settings.
SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true((SELECT count(*) = 0 FROM public.site_settings), 'customer cannot read settings table');
WITH changed AS (UPDATE public.site_settings SET shipping_default_rate = 1 RETURNING id)
SELECT pg_temp.assert_true((SELECT count(*) = 0 FROM changed), 'customer settings UPDATE denied by RLS');
SELECT pg_temp.expect_error($$INSERT INTO public.site_settings (site_name) VALUES ('Customer forbidden')$$,
  'row-level security', 'customer settings INSERT denied');
WITH changed AS (DELETE FROM public.site_settings RETURNING id)
SELECT pg_temp.assert_true((SELECT count(*) = 0 FROM changed), 'customer settings DELETE denied');
SELECT pg_temp.assert_true((pg_temp.checkout('Feni')->>'shipping_amount')::numeric = 1000000, 'authenticated checkout still supported');
RESET ROLE;
SELECT pg_temp.assert_true(EXISTS (SELECT 1 FROM public.orders WHERE user_id = '10000000-0000-0000-0000-000000000001'), 'authenticated order ownership preserved');
SELECT set_config('request.jwt.claim.sub', '', true);
SET LOCAL ROLE anon;
SELECT pg_temp.assert_true((SELECT count(*) = 0 FROM public.site_settings), 'anonymous cannot read settings table');
SELECT pg_temp.assert_true(public.get_public_settings() ? 'shipping_default_rate', 'anonymous public-settings RPC allowed');
SELECT pg_temp.assert_true((pg_temp.checkout('Chattogram')->>'shipping_amount')::numeric = 0, 'anonymous checkout allowed');
SELECT pg_temp.expect_error($$INSERT INTO public.site_settings (site_name) VALUES ('Anonymous forbidden')$$,
  'row-level security', 'anonymous settings INSERT denied');
RESET ROLE;
-- Corrupt cardinality is rejected, never silently LIMIT 1, never delete/clean rows.
INSERT INTO public.site_settings DEFAULT VALUES;
SELECT pg_temp.expect_error($$SELECT public.get_public_settings()$$, 'Shipping settings are ambiguous', 'duplicate public settings rejected');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Dhaka')$$, 'Shipping settings are ambiguous', 'duplicate checkout settings rejected');
SELECT pg_temp.assert_true((SELECT count(*) = 2 FROM public.site_settings), 'ambiguous rows not cleaned');
DELETE FROM public.site_settings;
SELECT pg_temp.expect_error($$SELECT public.get_public_settings()$$, 'Shipping settings are missing', 'missing public settings rejected');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Dhaka')$$, 'Shipping settings are missing', 'missing checkout settings rejected');
ROLLBACK;
