-- Run only in runner-owned private cluster, before applying the new migrations.
DO $$ BEGIN
  IF current_setting('nuhani.backend_test', true) IS DISTINCT FROM 'isolated'
     OR current_setting('listen_addresses') <> '' THEN
    RAISE EXCEPTION 'Tests require the private cluster created by run_backend_tests.py.';
  END IF;
END $$;
BEGIN;
ALTER TABLE public.orders DISABLE TRIGGER USER;
CREATE SCHEMA backend_test;
DO $$
DECLARE product_id uuid := '90000000-0000-0000-0000-000000000001';
  variant_id uuid := '90000000-0000-0000-0000-000000000002';
  product_name text := 'Historical product'; slug_name text := 'historical-fixture-product';
  shipping jsonb := jsonb_build_object('full_name','Historical guest','email','history@example.invalid',
    'phone','01700000009','address_line1','Local fixture','city','Chattogram','district','Chattogram');
BEGIN
  INSERT INTO public.products (id, name, slug) VALUES (product_id, product_name, slug_name);
  INSERT INTO public.product_variants (id, product_id, price, stock_quantity) VALUES (variant_id, product_id, 500, 50);
  PERFORM public.place_order(jsonb_build_array(jsonb_build_object('variant_id',variant_id,'quantity',2)), shipping, 'cod', NULL, NULL);
END;
$$;
CREATE TABLE backend_test.original_orders AS SELECT id, to_jsonb(o) AS snapshot FROM public.orders o;
CREATE TABLE backend_test.original_items AS SELECT id, to_jsonb(i) AS snapshot FROM public.order_items i;
CREATE TABLE backend_test.original_settings AS SELECT * FROM public.site_settings;
CREATE TABLE backend_test.original_stock AS SELECT id, stock_quantity FROM public.product_variants;
CREATE TABLE backend_test.original_functions AS SELECT p.oid, pg_get_functiondef(p.oid) AS definition, p.proacl, p.proowner
  FROM pg_proc p WHERE p.oid IN ('public.get_public_settings()'::regprocedure,
    'public.place_order(jsonb,jsonb,text,text,text)'::regprocedure);
CREATE TABLE backend_test.original_telegram_policies AS SELECT to_jsonb(p) AS snapshot FROM pg_policy p
  WHERE p.polrelid IN ('public.telegram_order_links'::regclass,'public.telegram_track_requests'::regclass);
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM backend_test.original_telegram_policies) THEN RAISE EXCEPTION 'Unexpected nonzero historical Telegram policy baseline'; END IF;
  RAISE NOTICE 'PASS: original Telegram baseline has zero policies on both RLS tables';
END $$;
CREATE TABLE backend_test.original_telegram_links AS SELECT to_jsonb(t) AS snapshot FROM public.telegram_order_links t;
CREATE TABLE backend_test.original_telegram_requests AS SELECT to_jsonb(t) AS snapshot FROM public.telegram_track_requests t;
COMMIT;
