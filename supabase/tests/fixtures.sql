-- Every suite is one transaction; fixtures and settings edits are rolled back.
DO $$ BEGIN
  IF current_setting('nuhani.backend_test', true) IS DISTINCT FROM 'isolated'
     OR current_setting('listen_addresses') <> '' THEN
    RAISE EXCEPTION 'Tests require the private cluster created by run_backend_tests.py.';
  END IF;
END $$;
BEGIN;
SET LOCAL lock_timeout = '5s';
-- Disable every order-side notification trigger, never the stock or profile guards.
ALTER TABLE public.orders DISABLE TRIGGER USER;
CREATE FUNCTION pg_temp.assert_true(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %', label; END IF;
  RAISE NOTICE 'PASS: %', label;
END;
$$;
CREATE FUNCTION pg_temp.expect_error(statement text, expected text, label text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE caught text;
BEGIN
  -- Statements are fixed test-source strings, never request input or interpolated SQL.
  BEGIN EXECUTE statement; EXCEPTION WHEN OTHERS THEN caught := SQLERRM; END;
  PERFORM pg_temp.assert_true(caught IS NOT NULL AND position(expected IN caught) > 0,
    label || coalesce(' (got ' || caught || ')', ' (no exception)'));
END;
$$;
DO $$
DECLARE
  customer_id uuid := '10000000-0000-0000-0000-000000000001';
  admin_id uuid := '10000000-0000-0000-0000-000000000002';
  insert_id uuid := '10000000-0000-0000-0000-000000000003';
  product_id uuid := '20000000-0000-0000-0000-000000000001';
  variant_id uuid := '30000000-0000-0000-0000-000000000001';
  customer_name text := 'Test customer'; admin_name text := 'Test admin';
  product_name text := 'Test product'; product_slug text := 'isolated-shipping-product';
  size_name text := 'M'; color_name text := 'Blue'; test_price numeric := 100;
BEGIN
  INSERT INTO auth.users (id, raw_user_meta_data) VALUES
    (customer_id, jsonb_build_object('full_name', customer_name, 'role', 'admin')),
    (admin_id, jsonb_build_object('full_name', admin_name)), (insert_id, '{}'::jsonb);
  UPDATE public.profiles SET role = 'admin' WHERE id = admin_id;
  -- Only our fresh-cluster fixture is removed, to test direct customer INSERT.
  DELETE FROM public.profiles WHERE id = insert_id;
  INSERT INTO public.products (id, name, slug) VALUES (product_id, product_name, product_slug);
  INSERT INTO public.product_variants (id, product_id, size, color, price, stock_quantity)
    VALUES (variant_id, product_id, size_name, color_name, test_price, 10000);
END;
$$;
CREATE FUNCTION pg_temp.checkout(district text, quantity integer DEFAULT 1,
  coupon text DEFAULT NULL, expected jsonb DEFAULT NULL, include_quote boolean DEFAULT false,
  city text DEFAULT 'Chattogram', division text DEFAULT 'Chattogram',
  expected_total jsonb DEFAULT NULL, include_total_quote boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  variant_id uuid := '30000000-0000-0000-0000-000000000001';
  shipping jsonb := jsonb_build_object('full_name', 'Fixture Buyer', 'phone', '01700000001',
    'email', 'fixture@example.invalid', 'address_line1', 'Local test only',
    'city', city, 'division', division, 'district', district);
BEGIN
  IF include_quote THEN shipping := shipping || jsonb_build_object('expected_shipping_amount', expected); END IF;
  IF include_total_quote THEN shipping := shipping || jsonb_build_object('expected_total_amount', expected_total); END IF;
  RETURN public.place_order(jsonb_build_array(jsonb_build_object('variant_id', variant_id,
    'quantity', quantity)), shipping, 'cod', coupon, ' Test notes ');
END;
$$;
