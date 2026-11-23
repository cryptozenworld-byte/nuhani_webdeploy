-- Configurable, server-authoritative shipping. Additive Supabase migration.
-- Copy of authoritative place_order from 20260907120000; only shipping/quote
-- sections change. Full latest whitelist from 20261109000000 is retained.
-- Rollback: supabase/tests/rollback_shipping_roles.sql (app rollback FIRST;
-- export the three shipping settings before dropping them). No orders are rewritten.
-- Supabase CLI / migration-verify owns the transaction, including its ledger write.
-- Manual application must use psql --single-transaction.
SET LOCAL lock_timeout = '5s';

-- Serialize cardinality validation with the following DDL. Do not seed, delete,
-- merge or choose an arbitrary existing row if configuration is corrupt.
LOCK TABLE public.site_settings IN ACCESS EXCLUSIVE MODE;
DO $$
DECLARE v_count bigint;
BEGIN
  SELECT count(*) INTO v_count FROM public.site_settings;
  IF v_count = 0 THEN
    RAISE EXCEPTION 'Shipping settings are missing. Migration requires exactly one site_settings row.';
  ELSIF v_count <> 1 THEN
    RAISE EXCEPTION 'Shipping settings are ambiguous. Migration requires exactly one site_settings row.';
  END IF;
END;
$$;

-- Unscaled numeric + integral CHECK rejects fractional inputs, unlike integer
-- casts or numeric(...,0), which silently round. Constant defaults are metadata-
-- only on supported PostgreSQL 11+; this tiny settings table needs no backfill.
ALTER TABLE public.site_settings
  ADD COLUMN IF NOT EXISTS shipping_chattogram_rate numeric NOT NULL DEFAULT 70,
  ADD COLUMN IF NOT EXISTS shipping_default_rate numeric NOT NULL DEFAULT 130,
  ADD COLUMN IF NOT EXISTS free_shipping_threshold numeric NOT NULL DEFAULT 3000;

-- IF NOT EXISTS must not silently accept type/default/constraint drift. Validate
-- existing definitions, without coercing types, rewriting data, or resetting rates.
DO $$
DECLARE v_column text; v_default text; v_constraint text; v_expected text;
BEGIN
  FOREACH v_column IN ARRAY ARRAY['shipping_chattogram_rate', 'shipping_default_rate', 'free_shipping_threshold'] LOOP
    v_default := CASE v_column WHEN 'shipping_chattogram_rate' THEN '70'
      WHEN 'shipping_default_rate' THEN '130' ELSE '3000' END;
    IF EXISTS (SELECT 1 FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
      WHERE a.attrelid = 'public.site_settings'::regclass AND a.attname = v_column
        AND (a.atttypid <> 'numeric'::regtype OR a.atttypmod <> -1 OR NOT a.attnotnull
          OR a.attgenerated <> '' OR a.attidentity <> '' OR d.oid IS NULL
          OR replace(regexp_replace(pg_get_expr(d.adbin, d.adrelid), '[()[:space:]]|::numeric', '', 'g'), '''', '')
            IS DISTINCT FROM v_default)) THEN
      RAISE EXCEPTION 'Existing shipping column % has an incompatible definition', v_column;
    END IF;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.site_settings'::regclass AND conname = 'shipping_chattogram_rate_whole_taka') THEN
    ALTER TABLE public.site_settings ADD CONSTRAINT shipping_chattogram_rate_whole_taka CHECK (
      shipping_chattogram_rate >= 0 AND shipping_chattogram_rate <= 1000000
      AND shipping_chattogram_rate = trunc(shipping_chattogram_rate));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.site_settings'::regclass AND conname = 'shipping_default_rate_whole_taka') THEN
    ALTER TABLE public.site_settings ADD CONSTRAINT shipping_default_rate_whole_taka CHECK (
      shipping_default_rate >= 0 AND shipping_default_rate <= 1000000
      AND shipping_default_rate = trunc(shipping_default_rate));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.site_settings'::regclass AND conname = 'free_shipping_threshold_whole_taka') THEN
    ALTER TABLE public.site_settings ADD CONSTRAINT free_shipping_threshold_whole_taka CHECK (
      free_shipping_threshold > 0 AND free_shipping_threshold <= 1000000
      AND free_shipping_threshold = trunc(free_shipping_threshold));
  END IF;

  FOREACH v_column IN ARRAY ARRAY['shipping_chattogram_rate', 'shipping_default_rate', 'free_shipping_threshold'] LOOP
    v_constraint := v_column || '_whole_taka';
    v_expected := v_column || CASE WHEN v_column = 'free_shipping_threshold' THEN '>0AND' ELSE '>=0AND' END
      || v_column || '<=1000000AND' || v_column || '=trunc' || v_column;
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.site_settings'::regclass AND conname = v_constraint
      AND (contype <> 'c' OR NOT convalidated OR connoinherit
        OR replace(regexp_replace(pg_get_expr(conbin, conrelid), '[()[:space:]]|::numeric', '', 'g'), '''', '')
          IS DISTINCT FROM v_expected)) THEN
      RAISE EXCEPTION 'Existing shipping constraint % has an incompatible definition', v_constraint;
    END IF;
  END LOOP;
END;
$$;

-- No table grants or settings policies are broadened. Only these three new
-- non-secret fields are added to the established explicit public whitelist.
CREATE OR REPLACE FUNCTION public.get_public_settings()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE s public.site_settings%rowtype;
BEGIN
  BEGIN
    SELECT * INTO STRICT s FROM public.site_settings;
  EXCEPTION
    WHEN no_data_found THEN
      RAISE EXCEPTION 'Shipping settings are missing. Please contact support.';
    WHEN too_many_rows THEN
      RAISE EXCEPTION 'Shipping settings are ambiguous. Please contact support.';
  END;
  RETURN jsonb_build_object(
    'logo_url', s.logo_url,
    'site_name', s.site_name,
    'phone', s.phone,
    'email', s.email,
    'address', s.address,
    'instagram_url', s.instagram_url,
    'facebook_url', s.facebook_url,
    'youtube_url', s.youtube_url,
    'twitter_url', s.twitter_url,
    'hero_image_url', s.hero_image_url,
    'hero_mobile_image_url', s.hero_mobile_image_url,
    'story_image_url', s.story_image_url,
    'about_hero_image_url', s.about_hero_image_url,
    'whatsapp_number', s.whatsapp_number,
    'telegram_bot_username', s.telegram_bot_username,
    'courier_provider', s.courier_provider,
    'shipping_chattogram_rate', s.shipping_chattogram_rate,
    'shipping_default_rate', s.shipping_default_rate,
    'free_shipping_threshold', s.free_shipping_threshold
  );
END;
$$;

-- Authoritative preview for stale guest prices/coupon metadata. This intentionally
-- mirrors the pricing/validation sections below without changing place_order's
-- locking or write path. Parity tests protect against drift between the two RPCs.
-- STABLE uses one current-data snapshot and prevents writes; no row locks are taken.
CREATE OR REPLACE FUNCTION public.get_order_quote(
  p_items jsonb,
  p_district text,
  p_coupon_code text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_subtotal numeric(10,2) := 0;
  v_discount numeric(10,2) := 0;
  v_shipping numeric(10,2);
  v_total numeric(10,2);
  v_district text := lower(btrim(coalesce(p_district, ''), E' \t\n\r\f'));
  v_settings public.site_settings%rowtype;
  v_coupon coupons%rowtype;
  v_coupon_found boolean := false;
  v_free_shipping boolean := false;
  v_quote_items jsonb := '[]'::jsonb;
  v_item jsonb;
  v_qty int;
  v_variant record;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Your cart is empty';
  END IF;
  IF v_district = '' THEN
    RAISE EXCEPTION 'Incomplete shipping address';
  END IF;

  BEGIN
    SELECT * INTO STRICT v_settings FROM public.site_settings;
  EXCEPTION
    WHEN no_data_found THEN
      RAISE EXCEPTION 'Shipping settings are missing. Please contact support.';
    WHEN too_many_rows THEN
      RAISE EXCEPTION 'Shipping settings are ambiguous. Please contact support.';
  END;
  v_shipping := CASE
    WHEN v_district IN ('chattogram', 'chittagong', 'চট্টগ্রাম')
      THEN v_settings.shipping_chattogram_rate
    ELSE v_settings.shipping_default_rate
  END;

  -- Preserve request line order and duplicates; never merge or trust client prices.
  FOR v_item IN
    SELECT value FROM jsonb_array_elements(p_items) WITH ORDINALITY AS lines(value, position)
    ORDER BY position
  LOOP
    v_qty := (v_item->>'quantity')::int;
    IF v_qty IS NULL OR v_qty <= 0 OR v_qty > 99 THEN
      RAISE EXCEPTION 'Invalid quantity';
    END IF;
    SELECT pv.price, pv.stock_quantity,
           pv.is_active AS variant_active, p.name AS product_name, p.is_active AS product_active
      INTO v_variant
      FROM product_variants pv
      JOIN products p ON p.id = pv.product_id
      WHERE pv.id = (v_item->>'variant_id')::uuid;
    IF NOT found THEN
      RAISE EXCEPTION 'A product in your cart is no longer available';
    END IF;
    IF NOT v_variant.variant_active OR NOT v_variant.product_active THEN
      RAISE EXCEPTION 'Product is not available: %', v_variant.product_name;
    END IF;
    IF v_variant.stock_quantity < v_qty THEN
      RAISE EXCEPTION 'Insufficient stock for % (requested %, available %)',
        v_variant.product_name, v_qty, v_variant.stock_quantity;
    END IF;
    v_subtotal := v_subtotal + (v_variant.price * v_qty);
    v_quote_items := v_quote_items || jsonb_build_array(jsonb_build_object(
      'variant_id', (v_item->>'variant_id')::uuid,
      'quantity', v_qty,
      'unit_price', v_variant.price,
      'total_price', v_variant.price * v_qty
    ));
  END LOOP;

  IF v_subtotal >= v_settings.free_shipping_threshold THEN
    v_shipping := 0;
  END IF;
  IF p_coupon_code IS NOT NULL AND btrim(p_coupon_code) <> '' THEN
    SELECT * INTO v_coupon
      FROM coupons
      WHERE upper(code) = upper(btrim(p_coupon_code));
    v_coupon_found := found;
    IF NOT v_coupon_found THEN
      RAISE EXCEPTION 'Invalid coupon code';
    END IF;
    IF NOT v_coupon.is_active THEN
      RAISE EXCEPTION 'This coupon is no longer active';
    END IF;
    IF v_coupon.expires_at IS NOT NULL AND v_coupon.expires_at < now() THEN
      RAISE EXCEPTION 'This coupon has expired';
    END IF;
    IF v_coupon.max_uses IS NOT NULL AND v_coupon.used_count >= v_coupon.max_uses THEN
      RAISE EXCEPTION 'This coupon has reached its usage limit';
    END IF;
    IF v_subtotal < v_coupon.min_order_amount THEN
      RAISE EXCEPTION 'This coupon requires a minimum order of % BDT', v_coupon.min_order_amount;
    END IF;
    IF v_coupon.type = 'percentage' THEN
      v_discount := round(v_subtotal * v_coupon.value / 100.0, 2);
    ELSIF v_coupon.type = 'flat' THEN
      v_discount := least(v_coupon.value, v_subtotal);
    ELSIF v_coupon.type = 'free_shipping' THEN
      v_discount := 0;
      v_free_shipping := true;
    END IF;
  END IF;
  IF v_free_shipping THEN
    v_shipping := 0;
  END IF;
  v_total := greatest(v_subtotal - v_discount + v_shipping, 0);
  RETURN jsonb_build_object(
    'subtotal', v_subtotal,
    'discount_amount', v_discount,
    'shipping_amount', v_shipping,
    'total_amount', v_total,
    'items', v_quote_items
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_order_quote(jsonb, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_order_quote(jsonb, text, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.place_order(
  p_items jsonb,            -- [{"variant_id": "...", "quantity": 2}, ...]
  p_shipping jsonb,         -- {full_name, phone, email, address_line1, address_line2, city, district, division, postal_code}
  p_payment_method text,
  p_coupon_code text,
  p_notes text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_subtotal numeric(10,2) := 0;
  v_discount numeric(10,2) := 0;
  v_shipping numeric(10,2);
  v_total numeric(10,2);
  v_district text := lower(btrim(coalesce(p_shipping->>'district', ''), E' \t\n\r\f'));
  v_settings public.site_settings%rowtype;
  v_expected_shipping numeric;
  v_expected_total numeric;
  v_coupon coupons%rowtype;
  v_coupon_found boolean := false;
  v_free_shipping boolean := false;
  v_order record;
  v_item jsonb;
  v_qty int;
  v_variant record;
BEGIN
  IF p_payment_method NOT IN ('bkash', 'nagad', 'card', 'cod') THEN
    RAISE EXCEPTION 'Invalid payment method';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Your cart is empty';
  END IF;
  IF coalesce(p_shipping->>'full_name', '') = ''
     OR coalesce(p_shipping->>'phone', '') = ''
     OR coalesce(p_shipping->>'address_line1', '') = ''
     OR coalesce(p_shipping->>'city', '') = ''
     OR v_district = '' THEN
    RAISE EXCEPTION 'Incomplete shipping address';
  END IF;
  IF v_user_id IS NULL AND coalesce(p_shipping->>'email', '') = '' THEN
    RAISE EXCEPTION 'Guest orders require an email address';
  END IF;

  -- One authoritative configuration row. Reject corruption; never pick LIMIT 1.
  -- Hold a shared row lock so rates cannot change during this order transaction.
  BEGIN
    SELECT * INTO STRICT v_settings FROM public.site_settings FOR SHARE;
  EXCEPTION
    WHEN no_data_found THEN
      RAISE EXCEPTION 'Shipping settings are missing. Please contact support.';
    WHEN too_many_rows THEN
      RAISE EXCEPTION 'Shipping settings are ambiguous. Please contact support.';
  END;
  v_shipping := CASE
    WHEN v_district IN ('chattogram', 'chittagong', 'চট্টগ্রাম')
      THEN v_settings.shipping_chattogram_rate
    ELSE v_settings.shipping_default_rate
  END;

  -- Price + validate every line (row locks prevent concurrent oversell)
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_qty := (v_item->>'quantity')::int;
    IF v_qty IS NULL OR v_qty <= 0 OR v_qty > 99 THEN
      RAISE EXCEPTION 'Invalid quantity';
    END IF;

    SELECT pv.price, pv.size, pv.color, pv.stock_quantity,
           pv.is_active AS variant_active, p.name AS product_name, p.is_active AS product_active
      INTO v_variant
      FROM product_variants pv
      JOIN products p ON p.id = pv.product_id
      WHERE pv.id = (v_item->>'variant_id')::uuid
      FOR UPDATE OF pv;

    IF NOT found THEN
      RAISE EXCEPTION 'A product in your cart is no longer available';
    END IF;
    IF NOT v_variant.variant_active OR NOT v_variant.product_active THEN
      RAISE EXCEPTION 'Product is not available: %', v_variant.product_name;
    END IF;
    IF v_variant.stock_quantity < v_qty THEN
      RAISE EXCEPTION 'Insufficient stock for % (requested %, available %)',
        v_variant.product_name, v_qty, v_variant.stock_quantity;
    END IF;

    v_subtotal := v_subtotal + (v_variant.price * v_qty);
  END LOOP;

  IF v_subtotal >= v_settings.free_shipping_threshold THEN
    v_shipping := 0;
  END IF;

  -- Coupon: revalidated server-side, never trusted from the client
  IF p_coupon_code IS NOT NULL AND btrim(p_coupon_code) <> '' THEN
    SELECT * INTO v_coupon
      FROM coupons
      WHERE upper(code) = upper(btrim(p_coupon_code))
      FOR UPDATE;
    v_coupon_found := found;

    IF NOT v_coupon_found THEN
      RAISE EXCEPTION 'Invalid coupon code';
    END IF;
    IF NOT v_coupon.is_active THEN
      RAISE EXCEPTION 'This coupon is no longer active';
    END IF;
    IF v_coupon.expires_at IS NOT NULL AND v_coupon.expires_at < now() THEN
      RAISE EXCEPTION 'This coupon has expired';
    END IF;
    IF v_coupon.max_uses IS NOT NULL AND v_coupon.used_count >= v_coupon.max_uses THEN
      RAISE EXCEPTION 'This coupon has reached its usage limit';
    END IF;
    IF v_subtotal < v_coupon.min_order_amount THEN
      RAISE EXCEPTION 'This coupon requires a minimum order of % BDT', v_coupon.min_order_amount;
    END IF;

    IF v_coupon.type = 'percentage' THEN
      v_discount := round(v_subtotal * v_coupon.value / 100.0, 2);
    ELSIF v_coupon.type = 'flat' THEN
      v_discount := least(v_coupon.value, v_subtotal);
    ELSIF v_coupon.type = 'free_shipping' THEN
      v_discount := 0;
      v_free_shipping := true;
    END IF;
  END IF;

  IF v_free_shipping THEN
    v_shipping := 0;
  END IF;

  -- Optional checkout quote is a stale-price guard, NEVER a source of pricing.
  -- Compare after threshold/coupon processing and before any INSERT/UPDATE,
  -- including the order-number sequence and deferred notification trigger.
  IF p_shipping ? 'expected_shipping_amount' THEN
    BEGIN
      v_expected_shipping := (p_shipping->>'expected_shipping_amount')::numeric;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      RAISE EXCEPTION 'Shipping charge has changed. Please review your order.';
    END;
    IF v_expected_shipping IS DISTINCT FROM v_shipping THEN
      RAISE EXCEPTION 'Shipping charge has changed. Please review your order.';
    END IF;
  END IF;

  v_total := greatest(v_subtotal - v_discount + v_shipping, 0);

  -- Optional final-total quote catches price/discount races even when shipping
  -- stays unchanged. It is only a review guard, never a pricing input.
  IF p_shipping ? 'expected_total_amount' THEN
    BEGIN
      v_expected_total := (p_shipping->>'expected_total_amount')::numeric;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      RAISE EXCEPTION 'Order total has changed. Please review your order.';
    END;
    IF v_expected_total IS DISTINCT FROM v_total THEN
      RAISE EXCEPTION 'Order total has changed. Please review your order.';
    END IF;
  END IF;

  INSERT INTO orders (
    user_id, guest_email, guest_phone,
    status, payment_method, payment_status,
    subtotal, discount_amount, shipping_amount, total_amount,
    coupon_code, shipping_address, notes
  ) VALUES (
    v_user_id,
    CASE WHEN v_user_id IS NULL THEN p_shipping->>'email' END,
    CASE WHEN v_user_id IS NULL THEN p_shipping->>'phone' END,
    'pending', p_payment_method, 'pending',
    v_subtotal, v_discount, v_shipping, v_total,
    CASE WHEN v_coupon_found THEN v_coupon.code END,
    p_shipping, NULLIF(btrim(coalesce(p_notes, '')), '')
  )
  RETURNING id, order_number INTO v_order;

  -- Line items + stock decrement in the same transaction
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_qty := (v_item->>'quantity')::int;

    SELECT pv.price, pv.size, pv.color, p.name AS product_name
      INTO v_variant
      FROM product_variants pv
      JOIN products p ON p.id = pv.product_id
      WHERE pv.id = (v_item->>'variant_id')::uuid;

    INSERT INTO order_items (order_id, variant_id, product_name, variant_details, quantity, unit_price, total_price)
    VALUES (
      v_order.id,
      (v_item->>'variant_id')::uuid,
      v_variant.product_name,
      jsonb_build_object('size', v_variant.size, 'color', v_variant.color),
      v_qty,
      v_variant.price,
      v_variant.price * v_qty
    );

    UPDATE product_variants
      SET stock_quantity = stock_quantity - v_qty
      WHERE id = (v_item->>'variant_id')::uuid;
  END LOOP;

  IF v_coupon_found THEN
    UPDATE coupons SET used_count = used_count + 1 WHERE id = v_coupon.id;
  END IF;

  RETURN jsonb_build_object(
    'id', v_order.id,
    'order_number', v_order.order_number,
    'subtotal', v_subtotal,
    'discount_amount', v_discount,
    'shipping_amount', v_shipping,
    'total_amount', v_total
  );
END;
$$;

-- CREATE OR REPLACE preserves existing ownership and grants; retain historical callers.
GRANT EXECUTE ON FUNCTION public.get_public_settings() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.place_order(jsonb, jsonb, text, text, text) TO anon, authenticated;
