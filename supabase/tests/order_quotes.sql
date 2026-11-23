\set ON_ERROR_STOP on
\ir fixtures.sql
CREATE FUNCTION pg_temp.quote(district text, quantity integer DEFAULT 1, coupon text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE variant_id uuid := '30000000-0000-0000-0000-000000000001';
BEGIN
  RETURN public.get_order_quote(jsonb_build_array(jsonb_build_object('variant_id', variant_id, 'quantity', quantity)), district, coupon);
END;
$$;
-- First call is the TDD regression: the prior implementation has no authoritative quote RPC.
SELECT pg_temp.assert_true(pg_temp.quote('Chattogram') = jsonb_build_object(
  'subtotal',100,'discount_amount',0,'shipping_amount',70,'total_amount',170,
  'items',jsonb_build_array(jsonb_build_object('variant_id','30000000-0000-0000-0000-000000000001',
    'quantity',1,'unit_price',100,'total_price',100))), 'quote returns authoritative totals and line prices');
CREATE FUNCTION pg_temp.quote_state() RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'orders', (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.orders o),
    'items', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.order_items i),
    'variants', (SELECT coalesce(jsonb_agg(to_jsonb(v) ORDER BY id),'[]'::jsonb) FROM public.product_variants v),
    'coupons', (SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY id),'[]'::jsonb) FROM public.coupons c),
    'settings', (SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY id),'[]'::jsonb) FROM public.site_settings s),
    'sequence', (SELECT last_value FROM public.order_number_seq))
$$;
CREATE FUNCTION pg_temp.assert_quote_parity(district text, quantity integer, coupon text,
  subtotal numeric, discount numeric, shipping numeric, total numeric, label text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE before_state jsonb; quote jsonb; actual_order jsonb;
BEGIN
  before_state := pg_temp.quote_state();
  quote := pg_temp.quote(district, quantity, coupon);
  PERFORM pg_temp.assert_true(quote = jsonb_build_object('subtotal',subtotal,'discount_amount',discount,
    'shipping_amount',shipping,'total_amount',total,
    'items',jsonb_build_array(jsonb_build_object('variant_id','30000000-0000-0000-0000-000000000001',
      'quantity',quantity,'unit_price',subtotal / quantity,'total_price',subtotal))), label || ': exact current quote and line prices');
  PERFORM pg_temp.assert_true(pg_temp.quote_state() = before_state, label || ': getter does not mutate orders/items/stock/coupons/settings/sequence');
  actual_order := pg_temp.checkout(district, quantity, coupon, quote->'shipping_amount', true,
    expected_total => quote->'total_amount', include_total_quote => true);
  PERFORM pg_temp.assert_true(actual_order - ARRAY['id','order_number'] = quote - 'items', label || ': quote totals match place_order');
  PERFORM pg_temp.assert_true((SELECT jsonb_agg(jsonb_build_object('variant_id',i.variant_id,'quantity',i.quantity,
    'unit_price',i.unit_price,'total_price',i.total_price)) FROM public.order_items i WHERE i.order_id = (actual_order->>'id')::uuid) = quote->'items',
    label || ': quoted line prices match persisted order items');
END;
$$;
SELECT pg_temp.assert_quote_parity(' ChItTaGoNg ',1,NULL,100,0,70,170,'normalized Chattogram rate');
SELECT pg_temp.assert_quote_parity('চট্টগ্রাম',1,NULL,100,0,70,170,'Bangla district rate');
SELECT pg_temp.assert_quote_parity('Feni',1,NULL,100,0,130,230,'default district rate');
SELECT pg_temp.assert_true((SELECT array_agg(key ORDER BY key) = ARRAY['discount_amount','items','shipping_amount','subtotal','total_amount']
  FROM jsonb_object_keys(pg_temp.quote('Feni')) AS keys(key)), 'quote exposes exactly five whitelisted fields');
SELECT pg_temp.assert_true((SELECT bool_and(jsonb_typeof(value) = 'number') FROM jsonb_each(pg_temp.quote('Feni') - 'items')),
  'all quote totals are numeric');
SELECT pg_temp.assert_true((SELECT array_agg(key ORDER BY key) = ARRAY['quantity','total_price','unit_price','variant_id']
  FROM jsonb_object_keys(pg_temp.quote('Feni')->'items'->0) AS keys(key)), 'quote item has exactly four whitelisted fields, no order/customer metadata');
DO $$
DECLARE
  first_id uuid := '30000000-0000-0000-0000-000000000001';
  second_id uuid := '30000000-0000-0000-0000-000000000002';
  product_id uuid := '20000000-0000-0000-0000-000000000001';
  second_price numeric := 12.34;
  request_lines jsonb; quote jsonb; before_state jsonb; actual_order jsonb; actual_lines jsonb; quoted_lines jsonb;
  shipping jsonb := jsonb_build_object('full_name','Quoted line buyer','phone','01700000001',
    'email','lines@example.invalid','address_line1','Local fixture','city','Chattogram','district','Chattogram');
BEGIN
  INSERT INTO public.product_variants (id,product_id,price,stock_quantity) VALUES (second_id,product_id,second_price,100);
  request_lines := jsonb_build_array(jsonb_build_object('variant_id',second_id,'quantity',2,'price',999),
    jsonb_build_object('variant_id',first_id,'quantity',3),jsonb_build_object('variant_id',second_id,'quantity',1));
  before_state := pg_temp.quote_state();
  quote := public.get_order_quote(request_lines,'Chattogram',NULL);
  PERFORM pg_temp.assert_true(quote->'items' = jsonb_build_array(
    jsonb_build_object('variant_id',second_id,'quantity',2,'unit_price',12.34,'total_price',24.68),
    jsonb_build_object('variant_id',first_id,'quantity',3,'unit_price',100,'total_price',300),
    jsonb_build_object('variant_id',second_id,'quantity',1,'unit_price',12.34,'total_price',12.34)),
    'quote preserves request line order, IDs, quantities, duplicate lines, and current decimal prices');
  PERFORM pg_temp.assert_true((SELECT sum((value->>'total_price')::numeric) FROM jsonb_array_elements(quote->'items'))
    = (quote->>'subtotal')::numeric, 'quoted line sum equals authoritative subtotal');
  PERFORM pg_temp.assert_true(pg_temp.quote_state() = before_state,'multi-line quote does not mutate data');
  shipping := shipping || jsonb_build_object('expected_shipping_amount',quote->'shipping_amount','expected_total_amount',quote->'total_amount');
  actual_order := public.place_order(request_lines,shipping,'cod',NULL,NULL);
  SELECT jsonb_agg(jsonb_build_object('variant_id',i.variant_id,'quantity',i.quantity,'unit_price',i.unit_price,'total_price',i.total_price)
    ORDER BY i.variant_id,i.quantity,i.unit_price,i.total_price) INTO actual_lines
    FROM public.order_items i WHERE i.order_id = (actual_order->>'id')::uuid;
  SELECT jsonb_agg(value ORDER BY value->>'variant_id',(value->>'quantity')::int,(value->>'unit_price')::numeric,(value->>'total_price')::numeric)
    INTO quoted_lines FROM jsonb_array_elements(quote->'items');
  PERFORM pg_temp.assert_true(actual_lines = quoted_lines,'multi-line quote matches every persisted order line including duplicates');
  PERFORM pg_temp.assert_true(actual_order - ARRAY['id','order_number'] = quote - 'items','multi-line quote totals match place_order');
END;
$$;
DO $$
DECLARE percent_code text := 'QUOTE_PERCENT'; flat_code text := 'QUOTE_FLAT'; free_code text := 'QUOTE_FREE';
  expired_code text := 'QUOTE_EXPIRED'; inactive_code text := 'QUOTE_INACTIVE'; used_code text := 'QUOTE_USED'; minimum_code text := 'QUOTE_MIN';
BEGIN
  INSERT INTO public.coupons (code,type,value) VALUES (percent_code,'percentage',12.5), (flat_code,'flat',25), (free_code,'free_shipping',0);
  INSERT INTO public.coupons (code,type,value,expires_at) VALUES (expired_code,'free_shipping',0,now() - interval '1 day');
  INSERT INTO public.coupons (code,type,value,is_active) VALUES (inactive_code,'free_shipping',0,false);
  INSERT INTO public.coupons (code,type,value,max_uses,used_count) VALUES (used_code,'free_shipping',0,1,1);
  INSERT INTO public.coupons (code,type,value,min_order_amount) VALUES (minimum_code,'free_shipping',0,9000);
END;
$$;
SELECT pg_temp.assert_quote_parity('Feni',1,' quote_percent ',100,12.5,130,217.5,'percentage coupon');
SELECT pg_temp.assert_quote_parity('Chattogram',1,'QUOTE_FLAT',100,25,70,145,'flat coupon');
SELECT pg_temp.assert_quote_parity('Feni',1,'QUOTE_FREE',100,0,0,100,'free shipping coupon');
-- Exact threshold and price refresh: cached 3000, live variant prices now total 2900.
UPDATE public.product_variants SET price = 1500 WHERE id = '30000000-0000-0000-0000-000000000001';
SELECT pg_temp.assert_quote_parity('Feni',2,NULL,3000,0,0,3000,'exact configured threshold');
SELECT pg_temp.assert_quote_parity('Feni',2,'QUOTE_PERCENT',3000,375,0,2625,'threshold remains pre-discount');
CREATE TEMP TABLE cached_price_quote AS SELECT pg_temp.quote('Feni',2) AS quote;
UPDATE public.product_variants SET price = 1450 WHERE id = '30000000-0000-0000-0000-000000000001';
SELECT pg_temp.assert_true((SELECT (quote->>'shipping_amount')::numeric = 0 FROM cached_price_quote), 'cached subtotal 3000 had free shipping');
SELECT pg_temp.assert_quote_parity('Feni',2,NULL,2900,0,130,3030,'live subtotal 2900 requotes paid shipping');
DO $$
DECLARE variant_id uuid := '30000000-0000-0000-0000-000000000001'; quote jsonb;
BEGIN
  quote := public.get_order_quote(jsonb_build_array(jsonb_build_object('variant_id',variant_id,'quantity',2,'price',1500)),'Feni',NULL);
  PERFORM pg_temp.assert_true((quote->>'subtotal')::numeric = 2900 AND (quote->>'shipping_amount')::numeric = 130,
    'quote ignores cached/client product prices');
END;
$$;
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Feni',2,NULL,'0',true)$$,
  'Shipping charge has changed. Please review your order.', 'stale cached threshold quote rejected');
-- Same coupon code changes type, so cached coupon metadata cannot produce a valid retry.
CREATE TEMP TABLE cached_coupon_quote AS SELECT pg_temp.quote('Feni',2,'QUOTE_FREE') AS quote;
UPDATE public.coupons SET type = 'flat', value = 50 WHERE code = 'QUOTE_FREE';
SELECT pg_temp.assert_true((SELECT (quote->>'shipping_amount')::numeric = 0 FROM cached_coupon_quote), 'cached free-shipping coupon had zero charge');
SELECT pg_temp.assert_quote_parity('Feni',2,'QUOTE_FREE',2900,50,130,2980,'coupon free-shipping to flat refresh');
SELECT pg_temp.expect_error($$SELECT pg_temp.checkout('Feni',2,'QUOTE_FREE','0',true)$$,
  'Shipping charge has changed. Please review your order.', 'stale coupon quote rejected');
UPDATE public.site_settings SET shipping_chattogram_rate = 85, shipping_default_rate = 145, free_shipping_threshold = 2900;
SELECT pg_temp.assert_quote_parity('Feni',2,NULL,2900,0,0,2900,'updated threshold exact boundary');
UPDATE public.site_settings SET free_shipping_threshold = 2901;
SELECT pg_temp.assert_quote_parity('Feni',2,NULL,2900,0,145,3045,'updated default rate below threshold');
SELECT pg_temp.assert_quote_parity('Chattogram',1,NULL,1450,0,85,1535,'updated Chattogram rate');
UPDATE public.product_variants SET price = 123.45 WHERE id = '30000000-0000-0000-0000-000000000001';
SELECT pg_temp.assert_quote_parity('Feni',3,'QUOTE_PERCENT',370.35,46.29,145,469.06,'cent-precise subtotal and percentage rounding');
CREATE TEMP TABLE before_invalid_quotes AS SELECT pg_temp.quote_state() AS snapshot;
SELECT pg_temp.expect_error($$SELECT pg_temp.quote('Feni',1,'UNKNOWN')$$,'Invalid coupon code','quote validates unknown coupon');
SELECT pg_temp.expect_error($$SELECT pg_temp.quote('Feni',1,'QUOTE_EXPIRED')$$,'expired','quote validates expiry');
SELECT pg_temp.expect_error($$SELECT pg_temp.quote('Feni',1,'QUOTE_INACTIVE')$$,'no longer active','quote validates coupon active flag');
SELECT pg_temp.expect_error($$SELECT pg_temp.quote('Feni',1,'QUOTE_USED')$$,'usage limit','quote validates coupon usage limit');
SELECT pg_temp.expect_error($$SELECT pg_temp.quote('Feni',1,'QUOTE_MIN')$$,'minimum order','quote validates minimum subtotal');
SELECT pg_temp.expect_error($$SELECT pg_temp.quote('Feni',0)$$,'Invalid quantity','quote validates quantities');
SELECT pg_temp.expect_error($$SELECT public.get_order_quote('[]'::jsonb,'Feni',NULL)$$,'cart is empty','quote rejects empty cart');
SELECT pg_temp.expect_error($$SELECT pg_temp.quote('   ')$$,'Incomplete shipping address','quote rejects blank district');
SELECT pg_temp.assert_true((SELECT snapshot = pg_temp.quote_state() FROM before_invalid_quotes),'failed quotes do not mutate data');
-- Real permissions: quote executes as anon/authenticated, even when settings rows are private.
SELECT set_config('request.jwt.claim.sub','',true);
SET LOCAL ROLE anon;
SELECT pg_temp.assert_true(pg_temp.quote('Feni') - 'items' = jsonb_build_object('subtotal',123.45,'discount_amount',0,'shipping_amount',145,'total_amount',268.45),
  'guest can get authoritative quote');
DO $$
DECLARE quote jsonb; actual_order jsonb;
BEGIN
  quote := pg_temp.quote('Feni',1,'QUOTE_FLAT');
  actual_order := pg_temp.checkout('Feni',1,'QUOTE_FLAT',quote->'shipping_amount',true,
    expected_total => quote->'total_amount', include_total_quote => true);
  PERFORM pg_temp.assert_true(actual_order - ARRAY['id','order_number'] = quote - 'items', 'guest quote matches guest place_order');
END;
$$;
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true(pg_temp.quote('Feni') - 'items' = jsonb_build_object('subtotal',123.45,'discount_amount',0,'shipping_amount',145,'total_amount',268.45),
  'authenticated customer can get identical quote');
DO $$
DECLARE quote jsonb; actual_order jsonb;
BEGIN
  quote := pg_temp.quote('Chattogram',1,'QUOTE_PERCENT');
  actual_order := pg_temp.checkout('Chattogram',1,'QUOTE_PERCENT',quote->'shipping_amount',true,
    expected_total => quote->'total_amount', include_total_quote => true);
  PERFORM pg_temp.assert_true(actual_order - ARRAY['id','order_number'] = quote - 'items', 'authenticated quote matches authenticated place_order');
END;
$$;
RESET ROLE;
SELECT pg_temp.assert_true((SELECT provolatile = 's' AND prosecdef FROM pg_proc WHERE oid = 'public.get_order_quote(jsonb,text,text)'::regprocedure),
  'quote is STABLE SECURITY DEFINER: read-only consistent snapshot');
SELECT pg_temp.assert_true((SELECT bool_and(atttypmod = -1) FROM pg_attribute WHERE attrelid = 'public.site_settings'::regclass
  AND attname IN ('shipping_chattogram_rate','shipping_default_rate','free_shipping_threshold')), 'shipping numeric fields have no rounding typmod');
SELECT pg_temp.expect_error($$UPDATE public.site_settings SET shipping_chattogram_rate = 70.001$$,'check constraint','sub-cent shipping values rejected without rounding');
SELECT pg_temp.expect_error($$UPDATE public.site_settings SET free_shipping_threshold = 3000.001$$,'check constraint','sub-cent thresholds rejected without rounding');
-- Missing/ambiguous settings fail closed for the getter too.
INSERT INTO public.site_settings DEFAULT VALUES;
SELECT pg_temp.expect_error($$SELECT pg_temp.quote('Feni')$$,'Shipping settings are ambiguous','quote rejects duplicate settings');
DELETE FROM public.site_settings;
SELECT pg_temp.expect_error($$SELECT pg_temp.quote('Feni')$$,'Shipping settings are missing','quote rejects missing settings');
ROLLBACK;
