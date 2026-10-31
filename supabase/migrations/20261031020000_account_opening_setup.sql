-- =========================================================
-- FAMILY BUDGET - INITIAL FINANCIAL SETUP
-- Migration 11
-- Opening date: 2026-11-01
-- Currency: EUR
-- =========================================================

-- =========================================================
-- 1. ACCOUNT OPENING CONFIRMATIONS
-- =========================================================

CREATE TABLE public.account_opening_confirmations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    household_id uuid NOT NULL,
    account_id uuid NOT NULL,

    opening_amount numeric(18,2) NOT NULL
        CHECK (
            opening_amount >= 0
            AND opening_amount < 10000000000000000
        ),

    opening_on date NOT NULL
        DEFAULT DATE '2026-11-01'
        CHECK (opening_on = DATE '2026-11-01'),

    transaction_id uuid,

    notes text
        CHECK (
            notes IS NULL
            OR char_length(notes) <= 2000
        ),

    confirmed_by uuid NOT NULL
        REFERENCES auth.users(id) ON DELETE RESTRICT,

    confirmed_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT opening_confirmation_account_fk
        FOREIGN KEY (household_id, account_id)
        REFERENCES public.accounts(household_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT opening_confirmation_transaction_fk
        FOREIGN KEY (household_id, transaction_id)
        REFERENCES public.transactions(household_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT opening_confirmation_once
        UNIQUE (household_id, account_id),

    CONSTRAINT opening_confirmation_transaction_unique
        UNIQUE (transaction_id),

    CONSTRAINT opening_confirmation_movement_rule
        CHECK (
            (
                opening_amount = 0
                AND transaction_id IS NULL
            )
            OR
            (
                opening_amount > 0
                AND transaction_id IS NOT NULL
            )
        )
);

-- =========================================================
-- 2. RLS AND AUDIT
-- =========================================================

ALTER TABLE public.account_opening_confirmations
ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.account_opening_confirmations
FROM PUBLIC, anon, authenticated;

GRANT SELECT ON public.account_opening_confirmations
TO authenticated;

CREATE POLICY opening_confirmations_select_member
ON public.account_opening_confirmations
FOR SELECT
TO authenticated
USING (
    private.is_household_member(household_id)
);

CREATE TRIGGER audit_account_opening_confirmations
AFTER INSERT OR UPDATE OR DELETE
ON public.account_opening_confirmations
FOR EACH ROW
EXECUTE FUNCTION private.audit_household_change();

CREATE TRIGGER protect_account_opening_confirmations
BEFORE UPDATE OR DELETE
ON public.account_opening_confirmations
FOR EACH ROW
EXECUTE FUNCTION private.block_financial_mutation();

-- =========================================================
-- 3. OWNER-ONLY OPENING CONFIRMATION
-- =========================================================

CREATE FUNCTION public.confirm_account_opening(
    p_household_id uuid,
    p_account_id uuid,
    p_amount numeric,
    p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_actor uuid;
    v_kind text;
    v_status text;
    v_credit_limit numeric(18,2);

    v_notes text;
    v_confirmation_id uuid;
    v_existing_amount numeric(18,2);
    v_existing_notes text;
    v_existing_transaction_id uuid;

    v_transaction_id uuid;
BEGIN
    -- Authorize Owner and serialize household operations.
    v_actor :=
        private.require_household_owner(p_household_id);

    IF p_account_id IS NULL THEN
        RAISE EXCEPTION 'Account ID required'
            USING ERRCODE = '22023';
    END IF;

    IF p_amount IS NULL
       OR p_amount < 0
       OR p_amount >= 10000000000000000
       OR p_amount <> pg_catalog.round(p_amount, 2)
    THEN
        RAISE EXCEPTION 'Invalid opening amount'
            USING ERRCODE = '22023';
    END IF;

    v_notes := NULLIF(pg_catalog.btrim(p_notes), '');

    IF pg_catalog.char_length(
        COALESCE(v_notes, '')
    ) > 2000 THEN
        RAISE EXCEPTION 'Opening notes exceed limit'
            USING ERRCODE = '22023';
    END IF;

    -- Lock account before reading or changing its ledger.
    SELECT a.kind, a.status
    INTO v_kind, v_status
    FROM public.accounts a
    WHERE a.id = p_account_id
      AND a.household_id = p_household_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account not found'
            USING ERRCODE = '42501';
    END IF;

    -- First check whether this account was initialized.
    SELECT
        c.id,
        c.opening_amount,
        c.notes,
        c.transaction_id
    INTO
        v_confirmation_id,
        v_existing_amount,
        v_existing_notes,
        v_existing_transaction_id
    FROM public.account_opening_confirmations c
    WHERE c.household_id = p_household_id
      AND c.account_id = p_account_id
    FOR UPDATE;

    IF v_confirmation_id IS NOT NULL THEN

        -- Identical retries are safe.
        IF v_existing_amount IS DISTINCT FROM p_amount
           OR v_existing_notes IS DISTINCT FROM v_notes
        THEN
            RAISE EXCEPTION
                'Opening already confirmed with different data'
                USING ERRCODE = '23505';
        END IF;

        RETURN pg_catalog.jsonb_build_object(
            'confirmation_id', v_confirmation_id,
            'account_id', p_account_id,
            'opening_amount', v_existing_amount,
            'transaction_id', v_existing_transaction_id,
            'already_confirmed', true
        );
    END IF;

    IF v_status IS DISTINCT FROM 'active' THEN
        RAISE EXCEPTION 'Account is not active'
            USING ERRCODE = '23514';
    END IF;

    IF v_kind NOT IN (
        'bank',
        'cash',
        'savings',
        'credit_card'
    ) THEN
        RAISE EXCEPTION 'Unsupported account type'
            USING ERRCODE = '22023';
    END IF;

        -- Validate opening credit debt against a known
    -- credit limit effective on the budget start date.
    IF v_kind = 'credit_card' AND p_amount > 0 THEN

        SELECT cl.limit_amount
        INTO v_credit_limit
        FROM public.credit_limit_history cl
        WHERE cl.household_id = p_household_id
          AND cl.account_id = p_account_id
          AND cl.effective_on <= DATE '2026-11-01'
        ORDER BY
            cl.effective_on DESC,
            cl.recorded_at DESC,
            cl.id DESC
        LIMIT 1;

        IF v_credit_limit IS NOT NULL
           AND p_amount > v_credit_limit
        THEN
            RAISE EXCEPTION
                'Opening credit debt exceeds credit limit'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    -- No opening confirmation after existing movements.
    IF EXISTS (
        SELECT 1
        FROM public.account_movements m
        WHERE m.household_id = p_household_id
          AND m.account_id = p_account_id
    ) THEN
        RAISE EXCEPTION
            'Account already has financial movements'
            USING ERRCODE = '23505';
    END IF;

    -- Zero is confirmed without a fake transaction.
    -- Positive amounts use the existing audited Ledger RPC.
    IF p_amount > 0 THEN
        v_transaction_id :=
            private.post_opening_balance_internal(
                p_household_id,
                p_account_id,
                p_amount,
                'opening:' || p_account_id::text,
                v_notes
            );
    END IF;

    -- This insert and the Ledger posting are atomic.
    INSERT INTO public.account_opening_confirmations (
        household_id,
        account_id,
        opening_amount,
        opening_on,
        transaction_id,
        notes,
        confirmed_by
    )
    VALUES (
        p_household_id,
        p_account_id,
        p_amount,
        DATE '2026-11-01',
        v_transaction_id,
        v_notes,
        v_actor
    )
    RETURNING id INTO v_confirmation_id;

    RETURN pg_catalog.jsonb_build_object(
        'confirmation_id', v_confirmation_id,
        'account_id', p_account_id,
        'opening_amount', p_amount,
        'transaction_id', v_transaction_id,
        'already_confirmed', false
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.confirm_account_opening(
        uuid, uuid, numeric, text
    )
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
    public.confirm_account_opening(
        uuid, uuid, numeric, text
    )
TO authenticated;

-- Disable the legacy untracked opening entry point.
-- Future opening setup must create its confirmation too.

REVOKE ALL ON FUNCTION
    public.post_opening_balance(
        uuid, uuid, numeric, text, text
    )
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION
    private.post_opening_balance_internal(
        uuid, uuid, numeric, text, text
    )
FROM PUBLIC, anon, authenticated;

-- =========================================================
-- 4. OWNER-ONLY INITIAL CREDIT LIMIT
-- =========================================================

CREATE FUNCTION public.confirm_initial_credit_limit(
    p_household_id uuid,
    p_account_id uuid,
    p_limit_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_actor uuid;
    v_kind text;
    v_status text;

    v_limit_id uuid;
    v_existing_limit numeric(18,2);
    v_existing_date date;
BEGIN
    -- Verify active Owner and lock household.
    v_actor :=
        private.require_household_owner(p_household_id);

    IF p_account_id IS NULL THEN
        RAISE EXCEPTION 'Account ID required'
            USING ERRCODE = '22023';
    END IF;

    IF p_limit_amount IS NULL
       OR p_limit_amount < 0
       OR p_limit_amount >= 10000000000000000
       OR p_limit_amount <>
          pg_catalog.round(p_limit_amount, 2)
    THEN
        RAISE EXCEPTION 'Invalid credit limit'
            USING ERRCODE = '22023';
    END IF;

    -- Lock the credit account.
    SELECT a.kind, a.status
    INTO v_kind, v_status
    FROM public.accounts a
    WHERE a.id = p_account_id
      AND a.household_id = p_household_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account not found'
            USING ERRCODE = '42501';
    END IF;

    IF v_kind IS DISTINCT FROM 'credit_card' THEN
        RAISE EXCEPTION 'Credit card required'
            USING ERRCODE = '22023';
    END IF;

    -- Existing initial limit: allow identical retries.
    SELECT
        cl.id,
        cl.limit_amount,
        cl.effective_on
    INTO
        v_limit_id,
        v_existing_limit,
        v_existing_date
    FROM public.credit_limit_history cl
    WHERE cl.household_id = p_household_id
      AND cl.account_id = p_account_id
    ORDER BY
        cl.effective_on,
        cl.recorded_at,
        cl.id
    LIMIT 1;

    IF v_limit_id IS NOT NULL THEN

        IF v_existing_date <> DATE '2026-11-01' THEN
            RAISE EXCEPTION
                'Credit limit history already exists'
                USING ERRCODE = '23514';
        END IF;

        IF v_existing_limit IS DISTINCT FROM p_limit_amount
        THEN
            RAISE EXCEPTION
                'Initial credit limit already confirmed'
                USING ERRCODE = '23505';
        END IF;

        RETURN pg_catalog.jsonb_build_object(
            'limit_id', v_limit_id,
            'account_id', p_account_id,
            'limit_amount', v_existing_limit,
            'already_confirmed', true
        );
    END IF;

    IF v_status IS DISTINCT FROM 'active' THEN
        RAISE EXCEPTION 'Account is not active'
            USING ERRCODE = '23514';
    END IF;

    -- Existing triggers validate credit limits against
    -- the complete historical principal timeline.
    INSERT INTO public.credit_limit_history (
        household_id,
        account_id,
        limit_amount,
        effective_on,
        reason,
        recorded_by
    )
    VALUES (
        p_household_id,
        p_account_id,
        p_limit_amount,
        DATE '2026-11-01',
        'Initial credit limit',
        v_actor
    )
    RETURNING id INTO v_limit_id;

    RETURN pg_catalog.jsonb_build_object(
        'limit_id', v_limit_id,
        'account_id', p_account_id,
        'limit_amount', p_limit_amount,
        'already_confirmed', false
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.confirm_initial_credit_limit(
        uuid, uuid, numeric
    )
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
    public.confirm_initial_credit_limit(
        uuid, uuid, numeric
    )
TO authenticated;

-- =========================================================
-- 5. DOCUMENT THE NEW INTERFACES
-- =========================================================

COMMENT ON TABLE public.account_opening_confirmations IS
    'Immutable one-time account opening confirmations. '
    'Zero is an explicit confirmation without a Ledger movement. '
    'Missing row means the opening amount is not confirmed.';

COMMENT ON FUNCTION
    public.confirm_account_opening(
        uuid, uuid, numeric, text
    )
IS
    'Owner-only one-time account opening. '
    'Positive amounts are posted atomically to the Ledger. '
    'Zero amounts create only an audited confirmation.';

COMMENT ON FUNCTION
    public.confirm_initial_credit_limit(
        uuid, uuid, numeric
    )
IS
    'Owner-only initial credit limit confirmation. '
    'Preserves append-only credit limit history.';