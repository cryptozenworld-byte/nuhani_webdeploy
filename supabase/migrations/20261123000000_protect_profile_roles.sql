-- Protect the privilege boundary used by is_admin() and settings RLS.
-- Apply with Supabase Migrate; rollback SQL is in supabase/tests/rollback_shipping_roles.sql.
-- Existing signup trigger inserts only id/full_name; role remains the customer default.
-- No request/user metadata or JWT role claim grants privileged database access.
-- Supabase CLI / migration-verify owns the transaction, including its ledger write.
-- Manual application must use psql --single-transaction.
SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION public.protect_profile_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  -- SECURITY DEFINER changes current_user. The active SET ROLE (or the direct
  -- session login when no SET ROLE exists) identifies the real database role.
  v_database_role text := coalesce(nullif(current_setting('role', true), 'none'), session_user);
  v_privileged boolean;
BEGIN
  v_privileged := v_database_role IN ('postgres', 'supabase_admin', 'supabase_auth_admin', 'service_role')
    OR (v_database_role = 'authenticated' AND public.is_admin());

  IF NOT v_privileged THEN
    IF TG_OP = 'INSERT' THEN
      IF NEW.role IS DISTINCT FROM 'customer' THEN
        RAISE EXCEPTION 'Profile role changes are restricted' USING ERRCODE = '42501';
      END IF;
    ELSE
      -- Check the OLD identity too; changing NEW.id must never bypass the guard.
      IF NEW.id IS DISTINCT FROM OLD.id THEN
        RAISE EXCEPTION 'Profile identity changes are restricted' USING ERRCODE = '42501';
      END IF;
      IF NEW.role IS DISTINCT FROM OLD.role THEN
        RAISE EXCEPTION 'Profile role changes are restricted' USING ERRCODE = '42501';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.protect_profile_role() FROM PUBLIC;
-- Preserve catalog identities on reapplication; reject conflicting definitions.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.profiles'::regclass AND tgname = 'profiles_protect_role') THEN
    CREATE TRIGGER profiles_protect_role
      BEFORE INSERT OR UPDATE ON public.profiles
      FOR EACH ROW EXECUTE FUNCTION public.protect_profile_role();
  ELSIF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.profiles'::regclass AND tgname = 'profiles_protect_role'
    AND (tgfoid <> 'public.protect_profile_role()'::regprocedure OR tgtype <> 23 OR tgenabled <> 'O'
      OR tgisinternal OR tgconstraint <> 0 OR tgqual IS NOT NULL OR tgattr <> ''::int2vector OR octet_length(tgargs) <> 0)) THEN
    RAISE EXCEPTION 'Existing profiles_protect_role trigger has an incompatible definition';
  END IF;
END;
$$;

-- Keep own-profile policies intact; only an already-established DB admin may
-- manage another profile. RLS still checks both the old and new row.
DO $$
DECLARE v_authenticated oid := (SELECT oid FROM pg_roles WHERE rolname = 'authenticated');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.profiles'::regclass AND polname = 'profiles_update_admin') THEN
    CREATE POLICY profiles_update_admin ON public.profiles FOR UPDATE
      TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
  ELSIF EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.profiles'::regclass AND polname = 'profiles_update_admin'
    AND (polcmd <> 'w' OR NOT polpermissive OR polroles <> ARRAY[v_authenticated]
      OR replace(pg_get_expr(polqual, polrelid), 'public.', '') IS DISTINCT FROM 'is_admin()'
      OR replace(pg_get_expr(polwithcheck, polrelid), 'public.', '') IS DISTINCT FROM 'is_admin()')) THEN
    RAISE EXCEPTION 'Existing profiles_update_admin policy has an incompatible definition';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.profiles'::regclass AND polname = 'profiles_insert_admin') THEN
    CREATE POLICY profiles_insert_admin ON public.profiles FOR INSERT
      TO authenticated WITH CHECK (public.is_admin());
  ELSIF EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.profiles'::regclass AND polname = 'profiles_insert_admin'
    AND (polcmd <> 'a' OR NOT polpermissive OR polroles <> ARRAY[v_authenticated] OR polqual IS NOT NULL
      OR replace(pg_get_expr(polwithcheck, polrelid), 'public.', '') IS DISTINCT FROM 'is_admin()')) THEN
    RAISE EXCEPTION 'Existing profiles_insert_admin policy has an incompatible definition';
  END IF;
END;
$$;

-- These existing Telegram tables historically had RLS enabled with zero policies
-- (implicit browser deny-all). Explicit restrictive policies preserve that access
-- boundary, including for authenticated admins; service-role BYPASSRLS is unchanged.
DO $$
DECLARE v_clients oid[] := (SELECT array_agg(oid ORDER BY oid) FROM pg_roles WHERE rolname IN ('anon', 'authenticated'));
BEGIN
  IF cardinality(v_clients) IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'Telegram deny policies require anon and authenticated database roles';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.telegram_order_links'::regclass AND polname = 'telegram_order_links_deny_clients') THEN
    CREATE POLICY telegram_order_links_deny_clients ON public.telegram_order_links
      AS RESTRICTIVE FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);
  ELSIF EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.telegram_order_links'::regclass AND polname = 'telegram_order_links_deny_clients'
    AND (polcmd <> '*' OR polpermissive OR cardinality(polroles) <> 2 OR NOT (polroles @> v_clients AND polroles <@ v_clients)
      OR pg_get_expr(polqual, polrelid) IS DISTINCT FROM 'false' OR pg_get_expr(polwithcheck, polrelid) IS DISTINCT FROM 'false')) THEN
    RAISE EXCEPTION 'Existing telegram_order_links_deny_clients policy has an incompatible definition';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.telegram_track_requests'::regclass AND polname = 'telegram_track_requests_deny_clients') THEN
    CREATE POLICY telegram_track_requests_deny_clients ON public.telegram_track_requests
      AS RESTRICTIVE FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);
  ELSIF EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.telegram_track_requests'::regclass AND polname = 'telegram_track_requests_deny_clients'
    AND (polcmd <> '*' OR polpermissive OR cardinality(polroles) <> 2 OR NOT (polroles @> v_clients AND polroles <@ v_clients)
      OR pg_get_expr(polqual, polrelid) IS DISTINCT FROM 'false' OR pg_get_expr(polwithcheck, polrelid) IS DISTINCT FROM 'false')) THEN
    RAISE EXCEPTION 'Existing telegram_track_requests_deny_clients policy has an incompatible definition';
  END IF;
END;
$$;
