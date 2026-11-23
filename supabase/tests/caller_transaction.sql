\set ON_ERROR_STOP on
-- Down-state fixture. Simulate the CLI applying schema and writing history in one
-- caller-owned transaction, then roll it back: neither schema nor history may remain.
BEGIN;
\ir ../migrations/20261123000000_protect_profile_roles.sql
\ir ../migrations/20261123000001_shipping_settings.sql
CREATE TABLE backend_test.atomic_ledger_probe (version text PRIMARY KEY);
DO $$ DECLARE version text := '20261123-test-only';
BEGIN INSERT INTO backend_test.atomic_ledger_probe VALUES (version); END $$;
ROLLBACK;
DO $$ BEGIN
 IF to_regprocedure('public.protect_profile_role()') IS NOT NULL
   OR to_regprocedure('public.get_order_quote(jsonb,text,text)') IS NOT NULL
   OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'site_settings'
     AND column_name = 'shipping_default_rate') OR to_regclass('backend_test.atomic_ledger_probe') IS NOT NULL
   OR EXISTS (SELECT 1 FROM pg_policy WHERE polname IN ('telegram_order_links_deny_clients','telegram_track_requests_deny_clients')
     AND polrelid IN ('public.telegram_order_links'::regclass,'public.telegram_track_requests'::regclass)) THEN
   RAISE EXCEPTION 'FAIL: migrations escaped the caller-owned transaction';
 END IF;
 RAISE NOTICE 'PASS: caller rollback atomically removes both migrations and simulated ledger write';
END $$;
