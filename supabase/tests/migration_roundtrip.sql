\set ON_ERROR_STOP on
-- Fresh-cluster only. The runner applies originals, then both forwards, then this script.
-- Helpers persist through transaction boundaries on the same connection.
\ir fixtures.sql
CREATE TEMP TABLE original_orders AS SELECT id, to_jsonb(o) AS snapshot FROM public.orders o;
-- Create a forward-priced order and preserve it throughout down/up.
SELECT pg_temp.checkout('Chattogram');
CREATE TEMP TABLE forward_orders AS SELECT id, to_jsonb(o) AS snapshot FROM public.orders o;
CREATE TEMP TABLE forward_items AS SELECT id, to_jsonb(i) AS snapshot FROM public.order_items i;
CREATE TEMP TABLE forward_settings AS SELECT id, to_jsonb(s) - ARRAY['shipping_chattogram_rate','shipping_default_rate','free_shipping_threshold'] AS snapshot FROM public.site_settings s;
CREATE TEMP TABLE forward_profiles AS SELECT id, to_jsonb(p) AS snapshot FROM public.profiles p;
COMMIT;
\ir rollback_shipping_roles.sql
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'site_settings'
  AND column_name IN ('shipping_chattogram_rate','shipping_default_rate','free_shipping_threshold')), 'down removes shipping columns');
SELECT pg_temp.assert_true(to_regprocedure('public.protect_profile_role()') IS NULL, 'down removes role guard');
SELECT pg_temp.assert_true(to_regprocedure('public.get_order_quote(jsonb,text,text)') IS NULL, 'down removes order quote RPC');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM forward_orders b JOIN public.orders o USING (id) WHERE b.snapshot <> to_jsonb(o)),
  'down preserves all existing order snapshots');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM forward_items b JOIN public.order_items i USING (id) WHERE b.snapshot <> to_jsonb(i)),
  'down preserves line snapshots');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM forward_settings b JOIN public.site_settings s USING (id) WHERE b.snapshot <> to_jsonb(s)),
  'down preserves all original settings and secrets');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM forward_profiles b JOIN public.profiles p USING (id) WHERE b.snapshot <> to_jsonb(p)),
  'down preserves all profiles');
SELECT pg_temp.assert_true((SELECT count(*) = 16 FROM jsonb_object_keys(public.get_public_settings())), 'down restores exact original 16-field whitelist');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM backend_test.original_functions b JOIN pg_proc p ON p.oid = b.oid
  WHERE b.definition <> pg_get_functiondef(p.oid)), 'down restores exact original authoritative functions');
SELECT pg_temp.assert_true(NOT EXISTS ((SELECT snapshot FROM backend_test.original_telegram_policies EXCEPT
  SELECT to_jsonb(p) FROM pg_policy p WHERE p.polrelid IN ('public.telegram_order_links'::regclass,'public.telegram_track_requests'::regclass)) UNION ALL
  (SELECT to_jsonb(p) FROM pg_policy p WHERE p.polrelid IN ('public.telegram_order_links'::regclass,'public.telegram_track_requests'::regclass) EXCEPT
  SELECT snapshot FROM backend_test.original_telegram_policies)), 'down restores exact original zero-policy Telegram baseline');
SELECT pg_temp.assert_true((SELECT bool_and(relrowsecurity) FROM pg_class WHERE oid IN
  ('public.telegram_order_links'::regclass,'public.telegram_track_requests'::regclass)), 'down retains Telegram RLS enabled and implicit deny-all');
-- The runner now tests failed missing/duplicate preflight against this down state,
-- then reapplies both forward migrations and runs migration_preservation.sql.
