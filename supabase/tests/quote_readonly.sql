\set ON_ERROR_STOP on
-- Historical fixture is committed only in the runner's disposable cluster.
-- READ ONLY forbids writes and row locks, independently of function inspection.
BEGIN READ ONLY;
SET LOCAL ROLE anon;
DO $$
DECLARE quote jsonb; variant_id uuid := '90000000-0000-0000-0000-000000000002';
BEGIN
  quote := public.get_order_quote(jsonb_build_array(jsonb_build_object('variant_id',variant_id,'quantity',2)),'Chattogram',NULL);
  IF quote <> jsonb_build_object('subtotal',1000,'discount_amount',0,'shipping_amount',70,'total_amount',1070,
    'items',jsonb_build_array(jsonb_build_object('variant_id',variant_id,'quantity',2,'unit_price',500,'total_price',1000))) THEN
    RAISE EXCEPTION 'FAIL: quote in READ ONLY transaction';
  END IF;
  RAISE NOTICE 'PASS: anonymous quote succeeds in a READ ONLY transaction without row locks';
END;
$$;
ROLLBACK;
