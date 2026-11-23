\set ON_ERROR_STOP on
\ir fixtures.sql
SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
SELECT set_config('request.jwt.claim.role', 'service_role', true); -- JWT role is NOT a privilege bypass.
SELECT set_config('request.jwt.claims', '{"user_metadata":{"role":"admin"},"role":"service_role"}', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.expect_error(
  $$UPDATE public.profiles SET role = 'admin' WHERE id = auth.uid()$$,
  'Profile role changes are restricted', 'customer cannot promote own role, even with forged metadata/claims');
UPDATE public.profiles SET full_name = 'Updated name', phone = '01700000002', role = 'customer' WHERE id = auth.uid();
SELECT pg_temp.assert_true((SELECT full_name = 'Updated name' AND role = 'customer' FROM public.profiles WHERE id = auth.uid()),
  'ordinary profile updates and unchanged role remain allowed');
SELECT pg_temp.expect_error(
  $$UPDATE public.profiles SET id = '10000000-0000-0000-0000-000000000003', role = 'admin' WHERE id = auth.uid()$$,
  'Profile', 'customer cannot change identity and role together');
SELECT pg_temp.expect_error(
  $$UPDATE public.profiles SET id = '10000000-0000-0000-0000-000000000003' WHERE id = auth.uid()$$,
  'Profile identity changes are restricted', 'customer cannot change profile identity');
SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
SELECT pg_temp.expect_error(
  $$INSERT INTO public.profiles (id, role) VALUES (auth.uid(), 'admin')$$,
  'Profile role changes are restricted', 'customer cannot INSERT admin profile');
INSERT INTO public.profiles (id, full_name) VALUES (auth.uid(), 'Ordinary insert');
SELECT pg_temp.assert_true((SELECT role = 'customer' FROM public.profiles WHERE id = auth.uid()), 'ordinary customer profile INSERT allowed');
RESET ROLE;
SELECT pg_temp.assert_true((SELECT role = 'customer' FROM public.profiles WHERE id = '10000000-0000-0000-0000-000000000001'),
  'signup metadata never promotes role');
-- Signup under the actual auth database role (no JWT subject) must still work.
SELECT set_config('request.jwt.claim.sub', '', true);
SET LOCAL ROLE supabase_auth_admin;
DO $$
DECLARE new_id uuid := '10000000-0000-0000-0000-000000000004'; metadata jsonb := '{"full_name":"Auth signup", "role":"admin"}';
BEGIN INSERT INTO auth.users (id, raw_user_meta_data) VALUES (new_id, metadata); END;
$$;
RESET ROLE;
SELECT pg_temp.assert_true((SELECT full_name = 'Auth signup' AND role = 'customer' FROM public.profiles
  WHERE id = '10000000-0000-0000-0000-000000000004'), 'auth signup trigger still creates customer profile');
DELETE FROM public.profiles WHERE id = '10000000-0000-0000-0000-000000000004';
SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
SET LOCAL ROLE authenticated;
UPDATE public.profiles SET role = 'admin' WHERE id = '10000000-0000-0000-0000-000000000003';
SELECT pg_temp.assert_true((SELECT role = 'admin' FROM public.profiles WHERE id = '10000000-0000-0000-0000-000000000003'),
  'established admin can manage another profile role');
INSERT INTO public.profiles (id, role) VALUES ('10000000-0000-0000-0000-000000000004', 'admin');
SELECT pg_temp.assert_true((SELECT role = 'admin' FROM public.profiles WHERE id = '10000000-0000-0000-0000-000000000004'),
  'established admin can create legitimate admin profile');
UPDATE public.profiles SET role = 'customer' WHERE id = auth.uid();
RESET ROLE;
SELECT pg_temp.assert_true((SELECT role = 'customer' FROM public.profiles WHERE id = '10000000-0000-0000-0000-000000000002'),
  'legitimate existing admin can change own role');
SET LOCAL ROLE service_role;
UPDATE public.profiles SET role = 'admin' WHERE id = '10000000-0000-0000-0000-000000000003';
RESET ROLE;
SELECT pg_temp.assert_true((SELECT role = 'admin' FROM public.profiles WHERE id = '10000000-0000-0000-0000-000000000003'),
  'service database role can manage roles');
UPDATE public.profiles SET role = 'customer' WHERE id = '10000000-0000-0000-0000-000000000003';
SELECT pg_temp.assert_true((SELECT role = 'customer' FROM public.profiles WHERE id = '10000000-0000-0000-0000-000000000003'),
  'direct database migration role can manage roles');
ROLLBACK;
