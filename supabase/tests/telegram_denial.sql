\set ON_ERROR_STOP on
\ir fixtures.sql
SELECT pg_temp.assert_true((SELECT count(*) = 2 FROM pg_policy
 WHERE polrelid IN ('public.telegram_order_links'::regclass,'public.telegram_track_requests'::regclass)
 AND polname IN ('telegram_order_links_deny_clients','telegram_track_requests_deny_clients')
 AND NOT polpermissive AND polcmd = '*'
 AND pg_get_expr(polqual,polrelid) = 'false' AND pg_get_expr(polwithcheck,polrelid) = 'false'),
 'both Telegram tables have explicit restrictive deny-all client policies');
DO $$
DECLARE order_id uuid; chat text := 'offline-test-chat';
BEGIN
 order_id := (pg_temp.checkout('Feni')->>'id')::uuid;
 PERFORM set_config('nuhani.test_order_id',order_id::text,true);
 INSERT INTO public.telegram_order_links (telegram_chat_id,order_id) VALUES (chat,order_id);
 INSERT INTO public.telegram_track_requests (telegram_chat_id,order_id) VALUES (chat,order_id);
END;
$$;
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true((SELECT count(*) = 0 FROM public.telegram_order_links),'customer cannot SELECT Telegram order links');
SELECT pg_temp.assert_true((SELECT count(*) = 0 FROM public.telegram_track_requests),'customer cannot SELECT Telegram track requests');
SELECT pg_temp.expect_error($$INSERT INTO public.telegram_order_links (telegram_chat_id,order_id)
 VALUES ('forbidden',current_setting('nuhani.test_order_id')::uuid)$$,'row-level security','customer cannot INSERT Telegram order links');
SELECT pg_temp.expect_error($$INSERT INTO public.telegram_track_requests (telegram_chat_id,order_id)
 VALUES ('forbidden',current_setting('nuhani.test_order_id')::uuid)$$,'row-level security','customer cannot INSERT Telegram track requests');
WITH changed AS (UPDATE public.telegram_order_links SET linked_at = now() RETURNING telegram_chat_id)
SELECT pg_temp.assert_true((SELECT count(*) = 0 FROM changed),'customer cannot UPDATE Telegram order links');
WITH changed AS (DELETE FROM public.telegram_track_requests RETURNING telegram_chat_id)
SELECT pg_temp.assert_true((SELECT count(*) = 0 FROM changed),'customer cannot DELETE Telegram track requests');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','',true);
SET LOCAL ROLE anon;
SELECT pg_temp.assert_true((SELECT count(*) = 0 FROM public.telegram_order_links),'anonymous cannot SELECT Telegram order links');
SELECT pg_temp.assert_true((SELECT count(*) = 0 FROM public.telegram_track_requests),'anonymous cannot SELECT Telegram track requests');
SELECT pg_temp.expect_error($$INSERT INTO public.telegram_order_links (telegram_chat_id,order_id)
 VALUES ('forbidden',current_setting('nuhani.test_order_id')::uuid)$$,'row-level security','anonymous cannot INSERT Telegram order links');
SELECT pg_temp.expect_error($$INSERT INTO public.telegram_track_requests (telegram_chat_id,order_id)
 VALUES ('forbidden',current_setting('nuhani.test_order_id')::uuid)$$,'row-level security','anonymous cannot INSERT Telegram track requests');
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM public.telegram_order_links),'service-role bypass can read Telegram order links');
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM public.telegram_track_requests),'service-role bypass can read Telegram track requests');
DO $$
DECLARE order_id uuid := current_setting('nuhani.test_order_id')::uuid; chat text := 'offline-service-test';
BEGIN
 INSERT INTO public.telegram_order_links (telegram_chat_id,order_id) VALUES (chat,order_id);
 INSERT INTO public.telegram_track_requests (telegram_chat_id,order_id) VALUES (chat,order_id);
END;
$$;
SELECT pg_temp.assert_true((SELECT count(*) = 2 FROM public.telegram_order_links),'service-role can insert Telegram order links');
SELECT pg_temp.assert_true((SELECT count(*) = 2 FROM public.telegram_track_requests),'service-role can insert Telegram track requests');
DELETE FROM public.telegram_order_links WHERE telegram_chat_id = 'offline-service-test';
DELETE FROM public.telegram_track_requests WHERE telegram_chat_id = 'offline-service-test';
RESET ROLE;
ROLLBACK;
