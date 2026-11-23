-- Local ephemeral PostgreSQL only. Minimal Supabase platform shims, not production setup.
DO $$ BEGIN
  IF current_setting('listen_addresses') <> '' THEN
    RAISE EXCEPTION 'Tests require a private Unix-socket-only cluster. Use run_backend_tests.py.';
  END IF;
END $$;
ALTER DATABASE postgres SET nuhani.backend_test = 'isolated';
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN BYPASSRLS;
CREATE ROLE supabase_auth_admin NOLOGIN;
CREATE ROLE authenticator NOLOGIN;
CREATE SCHEMA auth;
CREATE SCHEMA storage;
CREATE SCHEMA extensions;
CREATE SCHEMA net;
CREATE TABLE auth.users (id uuid PRIMARY KEY, raw_user_meta_data jsonb DEFAULT '{}'::jsonb);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.role', true), '')
$$;
CREATE TABLE storage.buckets (id text PRIMARY KEY, name text, public boolean);
CREATE TABLE storage.objects (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), bucket_id text);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
-- No HTTP extension is installed. Even an accidental invocation cannot contact a network.
CREATE FUNCTION net.http_post(url text, body jsonb DEFAULT '{}'::jsonb,
  params jsonb DEFAULT '{}'::jsonb, headers jsonb DEFAULT '{}'::jsonb,
  timeout_milliseconds integer DEFAULT 1000)
RETURNS bigint LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Outbound notifications disabled in isolated backend tests'; END;
$$;
GRANT USAGE ON SCHEMA auth, public TO anon, authenticated, service_role, supabase_auth_admin;
GRANT ALL ON auth.users TO supabase_auth_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
