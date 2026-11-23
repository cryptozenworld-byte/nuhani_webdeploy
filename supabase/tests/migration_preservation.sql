\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %', label; END IF;
  RAISE NOTICE 'PASS: %', label;
END;
$$;
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM backend_test.original_orders b LEFT JOIN public.orders o USING (id)
  WHERE o.id IS NULL OR b.snapshot <> to_jsonb(o)), 'forward preserves orders made before migration');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM backend_test.original_items b LEFT JOIN public.order_items i USING (id)
  WHERE i.id IS NULL OR b.snapshot <> to_jsonb(i)), 'forward preserves historical line snapshots');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM backend_test.original_stock b JOIN public.product_variants v USING (id)
  WHERE b.stock_quantity <> v.stock_quantity), 'forward does not change historical inventory');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM backend_test.original_functions b JOIN pg_proc p ON p.oid = b.oid
  WHERE b.proacl IS DISTINCT FROM p.proacl OR b.proowner IS DISTINCT FROM p.proowner), 'forward preserves function ownership and permissions');
SELECT pg_temp.assert_true((SELECT shipping_chattogram_rate = 70 AND shipping_default_rate = 130 AND free_shipping_threshold = 3000
  FROM public.site_settings), 'forward/reapply initializes correct defaults');
SELECT pg_temp.assert_true((SELECT count(*) = 19 FROM jsonb_object_keys(public.get_public_settings())), 'forward/reapply retains full public whitelist');
SELECT pg_temp.assert_true(to_regprocedure('public.protect_profile_role()') IS NOT NULL, 'forward/reapply installs role protection');
SELECT pg_temp.assert_true(to_regprocedure('public.get_order_quote(jsonb,text,text)') IS NOT NULL, 'forward/reapply installs read-only order quote');
SELECT pg_temp.assert_true((SELECT count(*) = 2 FROM pg_policy WHERE polrelid IN
  ('public.telegram_order_links'::regclass,'public.telegram_track_requests'::regclass)
  AND polname IN ('telegram_order_links_deny_clients','telegram_track_requests_deny_clients') AND NOT polpermissive),
  'forward/reapply installs both explicit Telegram client deny policies');
SELECT pg_temp.assert_true(NOT EXISTS ((SELECT snapshot FROM backend_test.original_telegram_links EXCEPT
  SELECT to_jsonb(t) FROM public.telegram_order_links t) UNION ALL
  (SELECT to_jsonb(t) FROM public.telegram_order_links t EXCEPT SELECT snapshot FROM backend_test.original_telegram_links)),
  'forward/reapply preserves historical Telegram link rows');
SELECT pg_temp.assert_true(NOT EXISTS ((SELECT snapshot FROM backend_test.original_telegram_requests EXCEPT
  SELECT to_jsonb(t) FROM public.telegram_track_requests t) UNION ALL
  (SELECT to_jsonb(t) FROM public.telegram_track_requests t EXCEPT SELECT snapshot FROM backend_test.original_telegram_requests)),
  'forward/reapply preserves historical Telegram request rows');
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM public.site_settings), 'exactly one settings row preserved');
ROLLBACK;
