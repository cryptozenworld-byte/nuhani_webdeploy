\set ON_ERROR_STOP on
-- Runner-owned private cluster only. Second apply must preserve existing data/config.
DO $$ BEGIN
  IF current_setting('nuhani.backend_test',true) IS DISTINCT FROM 'isolated' THEN
    RAISE EXCEPTION 'Tests require run_backend_tests.py';
  END IF;
END $$;
BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean,label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %',label; END IF; RAISE NOTICE 'PASS: %',label; END;
$$;
UPDATE public.site_settings SET shipping_chattogram_rate = 90, shipping_default_rate = 150, free_shipping_threshold = 4000;
CREATE TEMP TABLE twice_settings AS SELECT id,to_jsonb(s) AS snapshot FROM public.site_settings s;
CREATE TEMP TABLE twice_orders AS SELECT id,to_jsonb(o) AS snapshot FROM public.orders o;
CREATE TEMP TABLE twice_items AS SELECT id,to_jsonb(i) AS snapshot FROM public.order_items i;
CREATE TEMP TABLE twice_stock AS SELECT id,to_jsonb(v) AS snapshot FROM public.product_variants v;
CREATE TEMP TABLE twice_coupons AS SELECT id,to_jsonb(c) AS snapshot FROM public.coupons c;
CREATE TEMP TABLE twice_profiles AS SELECT id,to_jsonb(p) AS snapshot FROM public.profiles p;
CREATE TEMP TABLE twice_functions AS SELECT p.oid,p.proacl,p.proowner,p.provolatile,p.prosecdef,to_jsonb(p) AS snapshot
 FROM pg_proc p WHERE p.oid IN ('public.get_public_settings()'::regprocedure,
 'public.place_order(jsonb,jsonb,text,text,text)'::regprocedure,'public.get_order_quote(jsonb,text,text)'::regprocedure,
 'public.protect_profile_role()'::regprocedure);
CREATE TEMP TABLE twice_policies AS SELECT policyname,roles,cmd,qual,with_check FROM pg_policies
 WHERE schemaname = 'public' AND tablename = 'profiles';
CREATE FUNCTION pg_temp.catalog_state() RETURNS jsonb LANGUAGE sql AS $$
 SELECT jsonb_build_object(
  'triggers',(SELECT jsonb_agg(to_jsonb(t) ORDER BY t.oid) FROM pg_trigger t WHERE t.tgrelid = 'public.profiles'::regclass AND t.tgname = 'profiles_protect_role'),
  'policies',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.oid) FROM pg_policy p WHERE p.polrelid IN
    ('public.profiles'::regclass,'public.telegram_order_links'::regclass,'public.telegram_track_requests'::regclass)),
  'constraints',(SELECT jsonb_agg(to_jsonb(c) ORDER BY c.oid) FROM pg_constraint c WHERE c.conrelid = 'public.site_settings'::regclass
    AND c.conname IN ('shipping_chattogram_rate_whole_taka','shipping_default_rate_whole_taka','free_shipping_threshold_whole_taka')),
  'columns',(SELECT jsonb_agg(to_jsonb(a) ORDER BY a.attnum) FROM pg_attribute a WHERE a.attrelid = 'public.site_settings'::regclass
    AND a.attname IN ('shipping_chattogram_rate','shipping_default_rate','free_shipping_threshold')),
  'defaults',(SELECT jsonb_agg(to_jsonb(d) ORDER BY d.oid) FROM pg_attrdef d JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
    WHERE a.attrelid = 'public.site_settings'::regclass AND a.attname IN ('shipping_chattogram_rate','shipping_default_rate','free_shipping_threshold')))
$$;
CREATE TEMP TABLE twice_catalog AS SELECT pg_temp.catalog_state() AS snapshot;
COMMIT;
-- Test script, like the production CLI, owns each migration transaction.
BEGIN;
\ir ../migrations/20261123000000_protect_profile_roles.sql
COMMIT;
BEGIN;
\ir ../migrations/20261123000001_shipping_settings.sql
COMMIT;
BEGIN;
SELECT pg_temp.assert_true((SELECT shipping_chattogram_rate = 90 AND shipping_default_rate = 150 AND free_shipping_threshold = 4000
 FROM public.site_settings),'apply twice preserves configured 90/150/4000 values');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM twice_settings b LEFT JOIN public.site_settings s USING(id)
 WHERE s.id IS NULL OR b.snapshot <> to_jsonb(s)),'apply twice preserves complete settings row including credentials/timestamps');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM twice_orders b LEFT JOIN public.orders o USING(id)
 WHERE o.id IS NULL OR b.snapshot <> to_jsonb(o)),'apply twice preserves historical orders');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM twice_items b LEFT JOIN public.order_items i USING(id)
 WHERE i.id IS NULL OR b.snapshot <> to_jsonb(i)),'apply twice preserves historical line snapshots');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM twice_stock b LEFT JOIN public.product_variants v USING(id)
 WHERE v.id IS NULL OR b.snapshot <> to_jsonb(v)),'apply twice preserves stock');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM twice_coupons b LEFT JOIN public.coupons c USING(id)
 WHERE c.id IS NULL OR b.snapshot <> to_jsonb(c)),'apply twice preserves coupon state');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM twice_profiles b LEFT JOIN public.profiles p USING(id)
 WHERE p.id IS NULL OR b.snapshot <> to_jsonb(p)),'apply twice preserves profiles');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM twice_functions b LEFT JOIN pg_proc p ON p.oid = b.oid
 WHERE p.oid IS NULL OR b.proacl IS DISTINCT FROM p.proacl OR b.proowner IS DISTINCT FROM p.proowner
 OR b.provolatile <> p.provolatile OR b.prosecdef <> p.prosecdef OR b.snapshot <> to_jsonb(p)),
 'apply twice preserves function catalog identities, definitions, PUBLIC/anon/auth grants and security flags');
SELECT pg_temp.assert_true((SELECT snapshot = pg_temp.catalog_state() FROM twice_catalog),
 'apply twice preserves exact trigger/policy/constraint/column/default catalog fingerprint including OIDs');
SELECT pg_temp.assert_true(NOT EXISTS ((SELECT policyname,roles,cmd,qual,with_check FROM twice_policies EXCEPT
 SELECT policyname,roles,cmd,qual,with_check FROM pg_policies WHERE schemaname = 'public' AND tablename = 'profiles') UNION ALL
 (SELECT policyname,roles,cmd,qual,with_check FROM pg_policies WHERE schemaname = 'public' AND tablename = 'profiles' EXCEPT
 SELECT policyname,roles,cmd,qual,with_check FROM twice_policies)),'apply twice preserves all profile policies');
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM pg_trigger WHERE tgrelid = 'public.profiles'::regclass AND tgname = 'profiles_protect_role'),
 'apply twice leaves exactly one role-protection trigger');
SELECT pg_temp.assert_true((SELECT count(*) = 3 FROM pg_constraint WHERE conrelid = 'public.site_settings'::regclass
 AND conname IN ('shipping_chattogram_rate_whole_taka','shipping_default_rate_whole_taka','free_shipping_threshold_whole_taka') AND convalidated),
 'apply twice leaves exactly three validated shipping bounds constraints');
-- Restore the local fixture defaults so the existing full regression suite is unchanged.
UPDATE public.site_settings SET shipping_chattogram_rate = 70, shipping_default_rate = 130, free_shipping_threshold = 3000;
COMMIT;
