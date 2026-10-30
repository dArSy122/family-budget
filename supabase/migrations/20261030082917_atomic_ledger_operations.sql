
-- =========================================================
-- FAMILY BUDGET - ATOMIC LEDGER OPERATIONS
-- Migration: 20261030082917
-- =========================================================

-- STEP 1: SECURE HOUSEHOLD ACCESS GUARD

CREATE FUNCTION private.assert_active_household_member(
    p_household_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    -- An authenticated identity is mandatory.
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required'
            USING ERRCODE = '42501';
    END IF;

    -- The household must exist and remain active.
    IF NOT EXISTS (
        SELECT 1
        FROM public.households h
        WHERE h.id = p_household_id
          AND h.archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Household unavailable'
            USING ERRCODE = '42501';
    END IF;

    -- The current user must be an active member.
    IF NOT EXISTS (
        SELECT 1
        FROM public.household_members hm
        WHERE hm.household_id = p_household_id
          AND hm.user_id = auth.uid()
          AND hm.status = 'active'
    ) THEN
        RAISE EXCEPTION 'Household access denied'
            USING ERRCODE = '42501';
    END IF;
END;
$$;

-- Internal helper: no direct execution by API roles.
REVOKE ALL
ON FUNCTION private.assert_active_household_member(UUID)
FROM PUBLIC, anon, authenticated;

-- Future controlled posting functions will call this helper.
-- No financial writes are enabled by this step.



-- =========================================================
-- STEP 2: IDEMPOTENCY AND CONCURRENT REQUEST LOCKING
-- =========================================================

CREATE FUNCTION private.lock_ledger_idempotency(
    p_household_id UUID,
    p_idempotency_key TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
    -- Validate the idempotency key.
    IF p_idempotency_key IS NULL
       OR char_length(p_idempotency_key)
          NOT BETWEEN 1 AND 128
       OR btrim(p_idempotency_key) = ''
    THEN
        RAISE EXCEPTION 'Invalid idempotency key'
            USING ERRCODE = '22023';
    END IF;

    -- Verify active household membership.
    PERFORM private.assert_active_household_member(
        p_household_id
    );

    -- Serialize requests with the same household and key.
    -- The lock is released at transaction end.
    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
            p_household_id::TEXT
            || ':'
            || p_idempotency_key,
            0
        )
    );
END;
$$;

-- Internal function. No direct client execution.
REVOKE ALL
ON FUNCTION private.lock_ledger_idempotency(
    UUID,
    TEXT
)
FROM PUBLIC, anon, authenticated;

-- Future posting functions must:
-- 1. Acquire this lock.
-- 2. Look up an existing transaction by household and key.
-- 3. Verify that the existing request matches the new one.
-- 4. Return the original result for an identical request.
-- 5. Reject reuse of the key with different financial data.
-- 6. Insert transaction and movements atomically if new.
--
-- The existing UNIQUE(household_id, idempotency_key)
-- provides an additional database-level safeguard.



-- =========================================================
-- STEP 3: TRANSACTION REQUEST FINGERPRINT
-- =========================================================

-- All future financial transactions require an
-- idempotency key and a SHA-256 request fingerprint.
-- No real financial records exist at this stage.

ALTER TABLE public.transactions
    ALTER COLUMN idempotency_key SET NOT NULL;

ALTER TABLE public.transactions
    ADD CONSTRAINT transactions_idempotency_not_blank
    CHECK (btrim(idempotency_key) <> '');

ALTER TABLE public.transactions
    ADD COLUMN request_fingerprint TEXT NOT NULL
    CHECK (request_fingerprint ~ '^[0-9a-f]{64}$');


-- Create a deterministic fingerprint from JSONB.
-- The controlled posting function constructs
-- this payload from validated financial parameters.

CREATE FUNCTION private.ledger_request_fingerprint(
    p_payload JSONB
)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
STRICT
SECURITY INVOKER
SET search_path = ''
AS $$
    SELECT pg_catalog.encode(
        pg_catalog.sha256(
            pg_catalog.convert_to(
                p_payload::TEXT,
                'UTF8'
            )
        ),
        'hex'
    );
$$;

REVOKE ALL
ON FUNCTION private.ledger_request_fingerprint(JSONB)
FROM PUBLIC, anon, authenticated;


-- Find an existing transaction after acquiring
-- the transaction-scoped idempotency lock.

CREATE FUNCTION private.find_existing_ledger_transaction(
    p_household_id UUID,
    p_idempotency_key TEXT,
    p_request_payload JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    v_existing_id UUID;
    v_existing_fingerprint TEXT;
    v_request_fingerprint TEXT;
BEGIN
    -- Require a non-empty JSON object.
    IF p_request_payload IS NULL
       OR pg_catalog.jsonb_typeof(p_request_payload)
          IS DISTINCT FROM 'object'
       OR p_request_payload = '{}'::JSONB
    THEN
        RAISE EXCEPTION 'Invalid request payload'
            USING ERRCODE = '22023';
    END IF;

    -- Validate membership and serialize requests.
    PERFORM private.lock_ledger_idempotency(
        p_household_id,
        p_idempotency_key
    );

    -- Calculate fingerprint inside PostgreSQL.
    v_request_fingerprint :=
        private.ledger_request_fingerprint(
            p_request_payload
        );

    -- Look for a previously recorded operation.
    SELECT
        t.id,
        t.request_fingerprint
    INTO
        v_existing_id,
        v_existing_fingerprint
    FROM public.transactions t
    WHERE t.household_id = p_household_id
      AND t.idempotency_key = p_idempotency_key;

    IF FOUND THEN
        -- Reusing a key with different financial
        -- parameters is never allowed.
        IF v_existing_fingerprint
           IS DISTINCT FROM v_request_fingerprint
        THEN
            RAISE EXCEPTION
                'Idempotency key already used with different data'
                USING ERRCODE = '23505';
        END IF;

        -- Identical retry: return original transaction.
        RETURN v_existing_id;
    END IF;

    -- No existing transaction.
    -- The caller may create a new operation,
    -- using the same calculated fingerprint.
    RETURN NULL;
END;
$$;

REVOKE ALL
ON FUNCTION private.find_existing_ledger_transaction(
    UUID,
    TEXT,
    JSONB
)
FROM PUBLIC, anon, authenticated;


-- Posting functions will:
--
-- 1. Build a canonical JSONB payload containing
--    all material financial parameters.
--
-- 2. Call find_existing_ledger_transaction().
--
-- 3. Return the existing transaction on a retry.
--
-- 4. Otherwise insert the new transaction with
--    the same idempotency key and fingerprint.
--
-- 5. Insert all related ledger movements inside
--    the same PostgreSQL transaction.
--
-- The lock is held until the transaction ends.



-- =========================================================
-- STEP 4: ATOMIC INCOME POSTING
-- =========================================================

-- Internal privileged implementation.
-- The private schema is not exposed through Data API.

CREATE FUNCTION private.post_income_internal(
    p_household_id UUID,
    p_account_id UUID,
    p_amount NUMERIC,
    p_occurred_on DATE,
    p_idempotency_key TEXT,
    p_description TEXT,
    p_notes TEXT
)
RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor UUID;
    v_kind TEXT;
    v_status TEXT;
    v_description TEXT;
    v_notes TEXT;
    v_payload JSONB;
    v_transaction_id UUID;
BEGIN
    -- 1. Check authentication and household membership.

    PERFORM private.assert_active_household_member(
        p_household_id
    );

    v_actor := auth.uid();

    -- 2. Validate mandatory parameters.

    IF p_account_id IS NULL
       OR p_occurred_on IS NULL
    THEN
        RAISE EXCEPTION 'Missing required income parameters'
            USING ERRCODE = '22023';
    END IF;

    IF p_amount IS NULL
       OR p_amount <= 0
       OR p_amount >= 10000000000000000
       OR p_amount <> pg_catalog.round(p_amount, 2)
    THEN
        RAISE EXCEPTION 'Invalid income amount'
            USING ERRCODE = '22023';
    END IF;

    IF p_occurred_on < DATE '2026-11-01' THEN
        RAISE EXCEPTION 'Date precedes budget start'
            USING ERRCODE = '22023';
    END IF;

    -- 3. Normalize optional text fields.

    v_description := NULLIF(
        pg_catalog.btrim(p_description), ''
    );

    v_notes := NULLIF(
        pg_catalog.btrim(p_notes), ''
    );

    IF pg_catalog.char_length(
        COALESCE(v_description, '')
    ) > 250
    OR pg_catalog.char_length(
        COALESCE(v_notes, '')
    ) > 2000
    THEN
        RAISE EXCEPTION 'Income text exceeds allowed length'
            USING ERRCODE = '22023';
    END IF;

    -- 4. Build canonical request payload.

    v_payload := pg_catalog.jsonb_build_object(
        'operation', 'income_v1',
        'actor_user_id', v_actor,
        'household_id', p_household_id,
        'account_id', p_account_id,
        'amount', p_amount::NUMERIC(18,2),
        'occurred_on', p_occurred_on,
        'description', v_description,
        'notes', v_notes
    );

    -- 5. Serialize concurrent requests.
    -- Return the existing transaction for an
    -- identical retry.

    v_transaction_id :=
        private.find_existing_ledger_transaction(
            p_household_id,
            p_idempotency_key,
            v_payload
        );

    IF v_transaction_id IS NOT NULL THEN
        RETURN v_transaction_id;
    END IF;

    -- 6. Lock and validate destination account.

    SELECT a.kind, a.status
    INTO v_kind, v_status
    FROM public.accounts a
    WHERE a.id = p_account_id
      AND a.household_id = p_household_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account not found in household'
            USING ERRCODE = '22023';
    END IF;

    IF v_kind NOT IN ('bank', 'cash', 'savings') THEN
        RAISE EXCEPTION 'Invalid account type for income'
            USING ERRCODE = '22023';
    END IF;

    IF v_status <> 'active' THEN
        RAISE EXCEPTION 'Account is not active'
            USING ERRCODE = '22023';
    END IF;

    -- 7. Create the financial transaction.

    INSERT INTO public.transactions (
        household_id,
        kind,
        amount,
        occurred_on,
        description,
        notes,
        idempotency_key,
        request_fingerprint,
        created_by
    )
    VALUES (
        p_household_id,
        'income',
        p_amount,
        p_occurred_on,
        v_description,
        v_notes,
        p_idempotency_key,
        private.ledger_request_fingerprint(
            v_payload
        ),
        v_actor
    )
    RETURNING id INTO v_transaction_id;

    -- 8. Create the matching ledger movement.

    INSERT INTO public.account_movements (
        household_id,
        transaction_id,
        account_id,
        amount_delta
    )
    VALUES (
        p_household_id,
        v_transaction_id,
        p_account_id,
        p_amount
    );

    -- 9. Return the committed transaction ID.

    RETURN v_transaction_id;
END;
$$;

REVOKE ALL
ON FUNCTION private.post_income_internal(
    UUID, UUID, NUMERIC, DATE, TEXT, TEXT, TEXT
)
FROM PUBLIC, anon, authenticated;

-- Explicitly permit the authenticated wrapper
-- to invoke this validated private function.
GRANT EXECUTE
ON FUNCTION private.post_income_internal(
    UUID, UUID, NUMERIC, DATE, TEXT, TEXT, TEXT
)
TO authenticated;


-- =========================================================
-- PUBLIC RPC WRAPPER
-- Runs with caller permissions.
-- Privileged writes happen only in the private function.
-- =========================================================

CREATE FUNCTION public.post_income(
    p_household_id UUID,
    p_account_id UUID,
    p_amount NUMERIC,
    p_occurred_on DATE,
    p_idempotency_key TEXT,
    p_description TEXT DEFAULT NULL,
    p_notes TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE SQL
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
    SELECT private.post_income_internal(
        p_household_id,
        p_account_id,
        p_amount,
        p_occurred_on,
        p_idempotency_key,
        p_description,
        p_notes
    );
$$;

REVOKE ALL
ON FUNCTION public.post_income(
    UUID, UUID, NUMERIC, DATE, TEXT, TEXT, TEXT
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.post_income(
    UUID, UUID, NUMERIC, DATE, TEXT, TEXT, TEXT
)
TO authenticated;



-- =========================================================
-- STEP 5: ATOMIC OPENING BALANCE POSTING
-- Budget start: 2026-11-01
-- =========================================================

CREATE FUNCTION private.post_opening_balance_internal(
    p_household_id UUID,
    p_account_id UUID,
    p_amount NUMERIC,
    p_idempotency_key TEXT,
    p_notes TEXT
)
RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor UUID;
    v_account_kind TEXT;
    v_account_status TEXT;
    v_notes TEXT;
    v_payload JSONB;
    v_transaction_id UUID;
    v_description TEXT;
BEGIN
    -- 1. Require active household membership.

    PERFORM private.assert_active_household_member(
        p_household_id
    );

    -- 2. Only the household Owner may initialize balances.

    IF NOT private.is_household_owner(p_household_id) THEN
        RAISE EXCEPTION 'Owner permission required'
            USING ERRCODE = '42501';
    END IF;

    v_actor := auth.uid();

    -- 3. Validate account and monetary amount.
    -- Zero balances require no ledger transaction.

    IF p_account_id IS NULL THEN
        RAISE EXCEPTION 'Account is required'
            USING ERRCODE = '22023';
    END IF;

    IF p_amount IS NULL
       OR p_amount <= 0
       OR p_amount >= 10000000000000000
       OR p_amount <> pg_catalog.round(p_amount, 2)
    THEN
        RAISE EXCEPTION 'Invalid opening amount'
            USING ERRCODE = '22023';
    END IF;

    -- 4. Normalize optional notes.

    v_notes := NULLIF(
        pg_catalog.btrim(p_notes),
        ''
    );

    IF pg_catalog.char_length(
        COALESCE(v_notes, '')
    ) > 2000 THEN
        RAISE EXCEPTION 'Opening notes exceed limit'
            USING ERRCODE = '22023';
    END IF;

    -- 5. Construct canonical idempotency payload.

    v_payload := pg_catalog.jsonb_build_object(
        'operation', 'opening_balance_v1',
        'actor_user_id', v_actor,
        'household_id', p_household_id,
        'account_id', p_account_id,
        'amount', p_amount::NUMERIC(18,2),
        'occurred_on', DATE '2026-11-01',
        'notes', v_notes
    );

    -- 6. Lock idempotency key and resolve retries.

    v_transaction_id :=
        private.find_existing_ledger_transaction(
            p_household_id,
            p_idempotency_key,
            v_payload
        );

    IF v_transaction_id IS NOT NULL THEN
        RETURN v_transaction_id;
    END IF;

    -- 7. Lock the account to serialize posting.

    SELECT a.kind, a.status
    INTO v_account_kind, v_account_status
    FROM public.accounts a
    WHERE a.id = p_account_id
      AND a.household_id = p_household_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account not found in household'
            USING ERRCODE = '22023';
    END IF;

    IF v_account_status <> 'active' THEN
        RAISE EXCEPTION 'Account is not active'
            USING ERRCODE = '22023';
    END IF;

    -- 8. Opening balance must be the first
    -- financial movement of this account.
    -- Future posting functions must also lock
    -- the affected account before inserting movements.

    IF EXISTS (
        SELECT 1
        FROM public.account_movements m
        WHERE m.household_id = p_household_id
          AND m.account_id = p_account_id
    ) THEN
        RAISE EXCEPTION
            'Account already contains ledger movements'
            USING ERRCODE = '23505';
    END IF;

    -- 9. Credit cards carry positive outstanding debt.
    -- Ordinary accounts carry positive available funds.

    IF v_account_kind = 'credit_card' THEN
        v_description := 'Opening credit debt';
    ELSE
        v_description := 'Opening account balance';
    END IF;

    -- 10. Insert opening transaction.

    INSERT INTO public.transactions (
        household_id,
        kind,
        amount,
        occurred_on,
        description,
        notes,
        idempotency_key,
        request_fingerprint,
        created_by
    )
    VALUES (
        p_household_id,
        'opening_balance',
        p_amount,
        DATE '2026-11-01',
        v_description,
        v_notes,
        p_idempotency_key,
        private.ledger_request_fingerprint(v_payload),
        v_actor
    )
    RETURNING id INTO v_transaction_id;

    -- 11. Insert matching ledger movement.

    INSERT INTO public.account_movements (
        household_id,
        transaction_id,
        account_id,
        amount_delta
    )
    VALUES (
        p_household_id,
        v_transaction_id,
        p_account_id,
        p_amount
    );

    RETURN v_transaction_id;
END;
$$;

REVOKE ALL
ON FUNCTION private.post_opening_balance_internal(
    UUID, UUID, NUMERIC, TEXT, TEXT
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION private.post_opening_balance_internal(
    UUID, UUID, NUMERIC, TEXT, TEXT
)
TO authenticated;


-- =========================================================
-- PUBLIC RPC WRAPPER
-- =========================================================

CREATE FUNCTION public.post_opening_balance(
    p_household_id UUID,
    p_account_id UUID,
    p_amount NUMERIC,
    p_idempotency_key TEXT,
    p_notes TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE SQL
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
    SELECT private.post_opening_balance_internal(
        p_household_id,
        p_account_id,
        p_amount,
        p_idempotency_key,
        p_notes
    );
$$;

REVOKE ALL
ON FUNCTION public.post_opening_balance(
    UUID, UUID, NUMERIC, TEXT, TEXT
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.post_opening_balance(
    UUID, UUID, NUMERIC, TEXT, TEXT
)
TO authenticated;


-- =========================================================
-- STEP 6: ATOMIC EXPENSE POSTING
-- =========================================================

CREATE FUNCTION private.post_expense_internal(
    p_household_id UUID,
    p_account_id UUID,
    p_amount NUMERIC,
    p_occurred_on DATE,
    p_idempotency_key TEXT,
    p_description TEXT,
    p_notes TEXT
)
RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor UUID;
    v_account_kind TEXT;
    v_account_status TEXT;
    v_transaction_kind TEXT;

    v_description TEXT;
    v_notes TEXT;

    v_payload JSONB;
    v_transaction_id UUID;

    v_current_balance NUMERIC;
    v_credit_limit NUMERIC;
    v_movement_delta NUMERIC;
BEGIN
    -- 1. Verify authenticated household membership.

    PERFORM private.assert_active_household_member(
        p_household_id
    );

    v_actor := auth.uid();

    -- 2. Validate required parameters.

    IF p_account_id IS NULL
       OR p_occurred_on IS NULL
    THEN
        RAISE EXCEPTION 'Missing expense parameters'
            USING ERRCODE = '22023';
    END IF;

    IF p_amount IS NULL
       OR p_amount <= 0
       OR p_amount >= 10000000000000000
       OR p_amount <> pg_catalog.round(p_amount, 2)
    THEN
        RAISE EXCEPTION 'Invalid expense amount'
            USING ERRCODE = '22023';
    END IF;

    IF p_occurred_on < DATE '2026-11-01' THEN
        RAISE EXCEPTION 'Date precedes budget start'
            USING ERRCODE = '22023';
    END IF;

    -- 3. Normalize optional text fields.

    v_description := NULLIF(
        pg_catalog.btrim(p_description), ''
    );

    v_notes := NULLIF(
        pg_catalog.btrim(p_notes), ''
    );

    IF pg_catalog.char_length(
        COALESCE(v_description, '')
    ) > 250
    OR pg_catalog.char_length(
        COALESCE(v_notes, '')
    ) > 2000
    THEN
        RAISE EXCEPTION 'Expense text exceeds limit'
            USING ERRCODE = '22023';
    END IF;

    -- 4. Build canonical request payload.

    v_payload := pg_catalog.jsonb_build_object(
        'operation', 'expense_v1',
        'actor_user_id', v_actor,
        'household_id', p_household_id,
        'account_id', p_account_id,
        'amount', p_amount::NUMERIC(18,2),
        'occurred_on', p_occurred_on,
        'description', v_description,
        'notes', v_notes
    );

    -- 5. Lock idempotency key and detect retries.

    v_transaction_id :=
        private.find_existing_ledger_transaction(
            p_household_id,
            p_idempotency_key,
            v_payload
        );

    IF v_transaction_id IS NOT NULL THEN
        RETURN v_transaction_id;
    END IF;

    -- 6. Lock account before calculating balance.

    SELECT a.kind, a.status
    INTO v_account_kind, v_account_status
    FROM public.accounts a
    WHERE a.id = p_account_id
      AND a.household_id = p_household_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Account not found in household'
            USING ERRCODE = '22023';
    END IF;

    IF v_account_status <> 'active' THEN
        RAISE EXCEPTION 'Account is not active'
            USING ERRCODE = '22023';
    END IF;

    -- 7. Calculate current ledger balance.
    -- Bank/cash/savings: available money.
    -- Credit card: outstanding principal.

    SELECT COALESCE(
        SUM(m.amount_delta), 0
    )
    INTO v_current_balance
    FROM public.account_movements m
    WHERE m.household_id = p_household_id
      AND m.account_id = p_account_id;

    -- 8. Determine transaction and movement types.

    IF v_account_kind IN (
        'bank',
        'cash',
        'savings'
    ) THEN

        -- Do not allow an ordinary expense to
        -- create a negative available balance.

        IF v_current_balance < p_amount THEN
            RAISE EXCEPTION
                'Insufficient account balance'
                USING ERRCODE = '23514';
        END IF;

        -- Verify historical and future end-of-day balances.
        -- This also protects backdated expenses.

        PERFORM private.assert_nonnegative_account_timeline(
            p_household_id,
            p_account_id,
            p_occurred_on,
            -p_amount
        );

        v_transaction_kind := 'expense';
        v_movement_delta := -p_amount;


    ELSIF v_account_kind = 'credit_card' THEN

        -- Validate historical and future credit limits.

        PERFORM private.assert_credit_limit_timeline(
            p_household_id,
            p_account_id,
            p_occurred_on,
            p_amount
        );

        -- Credit charge increases outstanding principal.
        -- The purchase is recorded as an expense once.

        v_transaction_kind := 'credit_charge';
        v_movement_delta := p_amount;

    ELSE
        RAISE EXCEPTION
            'Unsupported expense account type'
            USING ERRCODE = '22023';
    END IF;


        -- 9. Insert financial transaction.

        INSERT INTO public.transactions (
            household_id,
            kind,
            amount,
            occurred_on,
            description,
            notes,
            idempotency_key,
            request_fingerprint,
            created_by
        )
        VALUES (
            p_household_id,
            v_transaction_kind,
            p_amount,
            p_occurred_on,
            v_description,
            v_notes,
            p_idempotency_key,
            private.ledger_request_fingerprint(
                v_payload
            ),
            v_actor
        )
        RETURNING id INTO v_transaction_id;

        -- 10. Insert matching ledger movement.

        INSERT INTO public.account_movements (
            household_id,
            transaction_id,
            account_id,
            amount_delta
        )
        VALUES (
            p_household_id,
            v_transaction_id,
            p_account_id,
            v_movement_delta
        );

        RETURN v_transaction_id;
    END;
    $$;

-- Restrict the privileged implementation.

    REVOKE ALL
    ON FUNCTION private.post_expense_internal(
        UUID, UUID, NUMERIC, DATE, TEXT, TEXT, TEXT
    )
    FROM PUBLIC, anon, authenticated;

    GRANT EXECUTE
    ON FUNCTION private.post_expense_internal(
        UUID, UUID, NUMERIC, DATE, TEXT, TEXT, TEXT
    )
    TO authenticated;


    -- =========================================================
    -- PUBLIC EXPENSE RPC
    -- =========================================================

    CREATE FUNCTION public.post_expense(
        p_household_id UUID,
        p_account_id UUID,
        p_amount NUMERIC,
        p_occurred_on DATE,
        p_idempotency_key TEXT,
        p_description TEXT DEFAULT NULL,
        p_notes TEXT DEFAULT NULL
    )
    RETURNS UUID
    LANGUAGE SQL
    VOLATILE
    SECURITY INVOKER
    SET search_path = ''
    AS $$
        SELECT private.post_expense_internal(
            p_household_id,
            p_account_id,
            p_amount,
            p_occurred_on,
            p_idempotency_key,
            p_description,
            p_notes
        );
    $$;

    REVOKE ALL
    ON FUNCTION public.post_expense(
        UUID, UUID, NUMERIC, DATE, TEXT, TEXT, TEXT
    )
    FROM PUBLIC, anon, authenticated;

    GRANT EXECUTE
    ON FUNCTION public.post_expense(
        UUID, UUID, NUMERIC, DATE, TEXT, TEXT, TEXT
    )
    TO authenticated;


    -- =========================================================
    -- STEP 7: ATOMIC ACCOUNT TRANSFERS
    -- =========================================================

    CREATE FUNCTION private.post_transfer_internal(
        p_household_id UUID,
        p_from_account_id UUID,
        p_to_account_id UUID,
        p_amount NUMERIC,
        p_occurred_on DATE,
        p_idempotency_key TEXT,
        p_description TEXT,
        p_notes TEXT
    )
    RETURNS UUID
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = ''
    AS $$
    DECLARE
        v_actor UUID;
        v_description TEXT;
        v_notes TEXT;

        v_payload JSONB;
        v_transaction_id UUID;

        v_account RECORD;
        v_locked_count INTEGER := 0;

        v_source_balance NUMERIC(18,2);
    BEGIN
    -- 1. Verify household membership.

    PERFORM private.assert_active_household_member(
        p_household_id
    );

    v_actor := auth.uid();

    -- 2. Validate required parameters.

    IF p_from_account_id IS NULL
       OR p_to_account_id IS NULL
       OR p_occurred_on IS NULL
    THEN
        RAISE EXCEPTION 'Missing transfer parameters'
            USING ERRCODE = '22023';
    END IF;

    -- Source and destination must be different.

    IF p_from_account_id = p_to_account_id THEN
        RAISE EXCEPTION
            'Source and destination must differ'
            USING ERRCODE = '22023';
    END IF;

    -- 3. Validate monetary amount.

    IF p_amount IS NULL
       OR p_amount <= 0
       OR p_amount >= 10000000000000000
       OR p_amount <> pg_catalog.round(p_amount, 2)
    THEN
        RAISE EXCEPTION 'Invalid transfer amount'
            USING ERRCODE = '22023';
    END IF;

    IF p_occurred_on < DATE '2026-11-01' THEN
        RAISE EXCEPTION 'Date precedes budget start'
            USING ERRCODE = '22023';
    END IF;

    -- 4. Normalize optional text fields.

    v_description := NULLIF(
        pg_catalog.btrim(p_description), ''
    );

    v_notes := NULLIF(
        pg_catalog.btrim(p_notes), ''
    );

    IF pg_catalog.char_length(
        COALESCE(v_description, '')
    ) > 250
    OR pg_catalog.char_length(
        COALESCE(v_notes, '')
    ) > 2000
    THEN
        RAISE EXCEPTION 'Transfer text exceeds limit'
            USING ERRCODE = '22023';
    END IF;

    -- 5. Build canonical request payload.

    v_payload := pg_catalog.jsonb_build_object(
        'operation', 'transfer_v1',
        'actor_user_id', v_actor,
        'household_id', p_household_id,
        'from_account_id', p_from_account_id,
        'to_account_id', p_to_account_id,
        'amount', p_amount::NUMERIC(18,2),
        'occurred_on', p_occurred_on,
        'description', v_description,
        'notes', v_notes
    );

    -- 6. Check idempotency and serialize retries.

    v_transaction_id :=
        private.find_existing_ledger_transaction(
            p_household_id,
            p_idempotency_key,
            v_payload
        );

    IF v_transaction_id IS NOT NULL THEN
        RETURN v_transaction_id;
    END IF;

    -- 7. Lock both accounts in deterministic order.
    -- This avoids opposite-direction transfer deadlocks.

    FOR v_account IN
        SELECT
            a.id,
            a.kind,
            a.status
        FROM public.accounts a
        WHERE a.household_id = p_household_id
          AND a.id IN (
              p_from_account_id,
              p_to_account_id
          )
        ORDER BY a.id
        FOR UPDATE OF a
    LOOP
        v_locked_count := v_locked_count + 1;

        -- Transfers support liquid accounts only.

        IF v_account.kind NOT IN (
            'bank',
            'cash',
            'savings'
        ) THEN
            RAISE EXCEPTION
                'Credit cards are not transfer accounts'
                USING ERRCODE = '22023';
        END IF;

        IF v_account.status <> 'active' THEN
            RAISE EXCEPTION
                'Transfer account is not active'
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    IF v_locked_count <> 2 THEN
        RAISE EXCEPTION
            'Both accounts must belong to the household'
            USING ERRCODE = '22023';
    END IF;

    -- 8. Calculate available source balance.
    -- All ledger writers must respect account locks.

    SELECT COALESCE(
        SUM(m.amount_delta), 0
    )
    INTO v_source_balance
    FROM public.account_movements m
    WHERE m.household_id = p_household_id
      AND m.account_id = p_from_account_id;

    -- 9. Prevent insufficient funds.


    IF v_source_balance < p_amount THEN
        RAISE EXCEPTION
            'Insufficient balance for transfer'
            USING ERRCODE = '23514';
    END IF;

    -- Verify historical and future end-of-day balances.
    -- Prevent backdated transfers from creating
    -- negative balances in the source account.

    PERFORM private.assert_nonnegative_account_timeline(
        p_household_id,
        p_from_account_id,
        p_occurred_on,
        -p_amount
    );


    -- 10. Insert transfer transaction.

    INSERT INTO public.transactions (
        household_id,
        kind,
        amount,
        occurred_on,
        description,
        notes,
        idempotency_key,
        request_fingerprint,
        created_by
    )
    VALUES (
        p_household_id,
        'transfer',
        p_amount,
        p_occurred_on,
        v_description,
        v_notes,
        p_idempotency_key,
        private.ledger_request_fingerprint(
            v_payload
        ),
        v_actor
    )
    RETURNING id INTO v_transaction_id;

    -- 11. Insert both ledger movements.
    -- Their sum must equal zero.

    INSERT INTO public.account_movements (
        household_id,
        transaction_id,
        account_id,
        amount_delta
    )
    VALUES
    (
        p_household_id,
        v_transaction_id,
        p_from_account_id,
        -p_amount
    ),
    (
        p_household_id,
        v_transaction_id,
        p_to_account_id,
        p_amount
    );

    -- 12. Return the transaction ID.

    RETURN v_transaction_id;
END;
$$;

REVOKE ALL
ON FUNCTION private.post_transfer_internal(
    UUID, UUID, UUID, NUMERIC,
    DATE, TEXT, TEXT, TEXT
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION private.post_transfer_internal(
    UUID, UUID, UUID, NUMERIC,
    DATE, TEXT, TEXT, TEXT
)
TO authenticated;


-- =========================================================
-- PUBLIC TRANSFER RPC
-- =========================================================

CREATE FUNCTION public.post_transfer(
    p_household_id UUID,
    p_from_account_id UUID,
    p_to_account_id UUID,
    p_amount NUMERIC,
    p_occurred_on DATE,
    p_idempotency_key TEXT,
    p_description TEXT DEFAULT NULL,
    p_notes TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE SQL
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
    SELECT private.post_transfer_internal(
        p_household_id,
        p_from_account_id,
        p_to_account_id,
        p_amount,
        p_occurred_on,
        p_idempotency_key,
        p_description,
        p_notes
    );
$$;

REVOKE ALL
ON FUNCTION public.post_transfer(
    UUID, UUID, UUID, NUMERIC,
    DATE, TEXT, TEXT, TEXT
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.post_transfer(
    UUID, UUID, UUID, NUMERIC,
    DATE, TEXT, TEXT, TEXT
)
TO authenticated;


-- =========================================================
-- STEP 8: ATOMIC CREDIT CARD PAYMENT
-- Interest & fees are expenses.
-- Only principal repayment reduces credit card debt.
-- =========================================================

CREATE FUNCTION private.post_credit_payment_internal(
    p_household_id UUID,
    p_payment_account_id UUID,
    p_credit_account_id UUID,
    p_interest_fees_amount NUMERIC,
    p_principal_amount NUMERIC,
    p_occurred_on DATE,
    p_idempotency_key TEXT,
    p_description TEXT,
    p_notes TEXT
)
RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor UUID;
    v_total_paid NUMERIC(18,2);

    v_description TEXT;
    v_notes TEXT;

    v_payload JSONB;
    v_transaction_id UUID;

    v_account RECORD;
    v_locked_count INTEGER := 0;

    v_payment_balance NUMERIC;
    v_remaining_principal NUMERIC;
BEGIN
    -- 1. Verify authenticated household membership.

    PERFORM private.assert_active_household_member(
        p_household_id
    );

    v_actor := auth.uid();

    -- 2. Validate required parameters.

    IF p_payment_account_id IS NULL
       OR p_credit_account_id IS NULL
       OR p_occurred_on IS NULL
    THEN
        RAISE EXCEPTION 'Missing credit payment parameters'
            USING ERRCODE = '22023';
    END IF;

    IF p_payment_account_id = p_credit_account_id THEN
        RAISE EXCEPTION 'Payment and credit accounts must differ'
            USING ERRCODE = '22023';
    END IF;

    -- 3. Validate interest and principal separately.

    IF p_interest_fees_amount IS NULL
       OR p_principal_amount IS NULL
       OR p_interest_fees_amount < 0
       OR p_principal_amount < 0
       OR p_interest_fees_amount <>
          pg_catalog.round(p_interest_fees_amount, 2)
       OR p_principal_amount <>
          pg_catalog.round(p_principal_amount, 2)
    THEN
        RAISE EXCEPTION 'Invalid credit payment components'
            USING ERRCODE = '22023';
    END IF;

    IF p_interest_fees_amount + p_principal_amount <= 0
       OR p_interest_fees_amount + p_principal_amount
          >= 10000000000000000
    THEN
        RAISE EXCEPTION 'Invalid total payment'
            USING ERRCODE = '22023';
    END IF;

    v_total_paid :=
        p_interest_fees_amount + p_principal_amount;

    IF p_occurred_on < DATE '2026-11-01' THEN
        RAISE EXCEPTION 'Date precedes budget start'
            USING ERRCODE = '22023';
    END IF;

    -- 4. Normalize optional text.

    v_description := NULLIF(
        pg_catalog.btrim(p_description), ''
    );

    v_notes := NULLIF(
        pg_catalog.btrim(p_notes), ''
    );

    IF pg_catalog.char_length(
        COALESCE(v_description, '')
    ) > 250
    OR pg_catalog.char_length(
        COALESCE(v_notes, '')
    ) > 2000
    THEN
        RAISE EXCEPTION 'Credit payment text exceeds limit'
            USING ERRCODE = '22023';
    END IF;

    -- 5. Build canonical idempotency payload.

    v_payload := pg_catalog.jsonb_build_object(
        'operation', 'credit_payment_v1',
        'actor_user_id', v_actor,
        'household_id', p_household_id,
        'payment_account_id', p_payment_account_id,
        'credit_account_id', p_credit_account_id,
        'interest_fees_amount',
            p_interest_fees_amount::NUMERIC(18,2),
        'principal_amount',
            p_principal_amount::NUMERIC(18,2),
        'total_paid', v_total_paid,
        'occurred_on', p_occurred_on,
        'description', v_description,
        'notes', v_notes
    );

    -- 6. Serialize requests and detect retries.

    v_transaction_id :=
        private.find_existing_ledger_transaction(
            p_household_id,
            p_idempotency_key,
            v_payload
        );

    IF v_transaction_id IS NOT NULL THEN
        RETURN v_transaction_id;
    END IF;

    -- 7. Lock both accounts in deterministic order.

    FOR v_account IN
        SELECT a.id, a.kind, a.status
        FROM public.accounts a
        WHERE a.household_id = p_household_id
          AND a.id IN (
              p_payment_account_id,
              p_credit_account_id
          )
        ORDER BY a.id
        FOR UPDATE OF a
    LOOP
        v_locked_count := v_locked_count + 1;

        IF v_account.status <> 'active' THEN
            RAISE EXCEPTION 'Account is not active'
                USING ERRCODE = '22023';
        END IF;

        IF v_account.id = p_payment_account_id
           AND v_account.kind NOT IN (
               'bank', 'cash', 'savings'
           )
        THEN
            RAISE EXCEPTION 'Invalid payment account type'
                USING ERRCODE = '22023';
        END IF;

        IF v_account.id = p_credit_account_id
           AND v_account.kind <> 'credit_card'
        THEN
            RAISE EXCEPTION 'Target must be a credit card'
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    IF v_locked_count <> 2 THEN
        RAISE EXCEPTION 'Accounts not found in household'
            USING ERRCODE = '22023';
    END IF;

    -- 8. Calculate available payment funds.

    SELECT COALESCE(SUM(m.amount_delta), 0)
    INTO v_payment_balance
    FROM public.account_movements m
    WHERE m.household_id = p_household_id
      AND m.account_id = p_payment_account_id;

    IF v_payment_balance < v_total_paid THEN
        RAISE EXCEPTION 'Insufficient payment balance'
            USING ERRCODE = '23514';
    END IF;


    -- Verify historical availability of payment funds.
    -- The full payment includes interest, fees and principal.

    PERFORM private.assert_nonnegative_account_timeline(
        p_household_id,
        p_payment_account_id,
        p_occurred_on,
        -v_total_paid
    );


    -- 9. Calculate current outstanding principal.

    SELECT COALESCE(SUM(m.amount_delta), 0)
    INTO v_remaining_principal
    FROM public.account_movements m
    WHERE m.household_id = p_household_id
      AND m.account_id = p_credit_account_id;

    IF v_remaining_principal < 0 THEN
        RAISE EXCEPTION 'Invalid credit principal balance'
            USING ERRCODE = '23514';
    END IF;

    -- Never repay more principal than currently owed.

    IF p_principal_amount > v_remaining_principal THEN
        RAISE EXCEPTION 'Principal repayment exceeds debt'
            USING ERRCODE = '23514';
    END IF;


    -- Only principal repayment reduces credit debt.
    -- Interest and fees do not affect principal.

    IF p_principal_amount > 0 THEN
        PERFORM private.assert_nonnegative_account_timeline(
            p_household_id,
            p_credit_account_id,
            p_occurred_on,
            -p_principal_amount
        );
    END IF;


    -- 10. Create one credit payment transaction.

    INSERT INTO public.transactions (
        household_id,
        kind,
        amount,
        interest_fees_amount,
        principal_amount,
        occurred_on,
        description,
        notes,
        idempotency_key,
        request_fingerprint,
        created_by
    )
    VALUES (
        p_household_id,
        'credit_payment',
        v_total_paid,
        p_interest_fees_amount,
        p_principal_amount,
        p_occurred_on,
        v_description,
        v_notes,
        p_idempotency_key,
        private.ledger_request_fingerprint(v_payload),
        v_actor
    )
    RETURNING id INTO v_transaction_id;

    -- 11. Deduct the full payment from the source.

    INSERT INTO public.account_movements (
        household_id,
        transaction_id,
        account_id,
        amount_delta
    )
    VALUES (
        p_household_id,
        v_transaction_id,
        p_payment_account_id,
        -v_total_paid
    );

    -- 12. Reduce credit debt by principal ONLY.
    -- Interest-only payments create no card movement.

    IF p_principal_amount > 0 THEN
        INSERT INTO public.account_movements (
            household_id,
            transaction_id,
            account_id,
            amount_delta
        )
        VALUES (
            p_household_id,
            v_transaction_id,
            p_credit_account_id,
            -p_principal_amount
        );
    END IF;

    RETURN v_transaction_id;
END;
$$;

REVOKE ALL
ON FUNCTION private.post_credit_payment_internal(
    UUID, UUID, UUID, NUMERIC, NUMERIC,
    DATE, TEXT, TEXT, TEXT
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION private.post_credit_payment_internal(
    UUID, UUID, UUID, NUMERIC, NUMERIC,
    DATE, TEXT, TEXT, TEXT
)
TO authenticated;


-- =========================================================
-- PUBLIC CREDIT PAYMENT RPC
-- =========================================================

CREATE FUNCTION public.post_credit_payment(
    p_household_id UUID,
    p_payment_account_id UUID,
    p_credit_account_id UUID,
    p_interest_fees_amount NUMERIC,
    p_principal_amount NUMERIC,
    p_occurred_on DATE,
    p_idempotency_key TEXT,
    p_description TEXT DEFAULT NULL,
    p_notes TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE SQL
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
    SELECT private.post_credit_payment_internal(
        p_household_id,
        p_payment_account_id,
        p_credit_account_id,
        p_interest_fees_amount,
        p_principal_amount,
        p_occurred_on,
        p_idempotency_key,
        p_description,
        p_notes
    );
$$;

REVOKE ALL
ON FUNCTION public.post_credit_payment(
    UUID, UUID, UUID, NUMERIC, NUMERIC,
    DATE, TEXT, TEXT, TEXT
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.post_credit_payment(
    UUID, UUID, UUID, NUMERIC, NUMERIC,
    DATE, TEXT, TEXT, TEXT
)
TO authenticated;


-- =========================================================
-- STEP 9: ATOMIC REFUND POSTING
-- Refunds reduce the original expense, not income.
-- =========================================================

CREATE FUNCTION private.post_refund_internal(
    p_household_id UUID,
    p_original_transaction_id UUID,
    p_amount NUMERIC,
    p_occurred_on DATE,
    p_idempotency_key TEXT,
    p_description TEXT,
    p_notes TEXT
)
RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor UUID;

    v_description TEXT;
    v_notes TEXT;

    v_payload JSONB;
    v_transaction_id UUID;

    v_original_kind TEXT;
    v_original_amount NUMERIC(18,2);
    v_original_date DATE;

    v_account_id UUID;
    v_account_kind TEXT;
    v_account_status TEXT;
    v_original_delta NUMERIC(18,2);

    v_movement_count INTEGER;
    v_already_refunded NUMERIC(18,2);
    v_current_balance NUMERIC(18,2);
    v_refundable_amount NUMERIC(18,2);
    v_refund_delta NUMERIC(18,2);
BEGIN
    -- 1. Verify authenticated household membership.

    PERFORM private.assert_active_household_member(
        p_household_id
    );

    v_actor := auth.uid();

    -- 2. Validate required parameters.

    IF p_original_transaction_id IS NULL
       OR p_occurred_on IS NULL
    THEN
        RAISE EXCEPTION 'Missing refund parameters'
            USING ERRCODE = '22023';
    END IF;

    IF p_amount IS NULL
       OR p_amount <= 0
       OR p_amount >= 10000000000000000
       OR p_amount <> pg_catalog.round(p_amount, 2)
    THEN
        RAISE EXCEPTION 'Invalid refund amount'
            USING ERRCODE = '22023';
    END IF;

    IF p_occurred_on < DATE '2026-11-01' THEN
        RAISE EXCEPTION 'Date precedes budget start'
            USING ERRCODE = '22023';
    END IF;

    -- 3. Normalize optional text.

    v_description := NULLIF(
        pg_catalog.btrim(p_description), ''
    );

    v_notes := NULLIF(
        pg_catalog.btrim(p_notes), ''
    );

    IF pg_catalog.char_length(
        COALESCE(v_description, '')
    ) > 250
    OR pg_catalog.char_length(
        COALESCE(v_notes, '')
    ) > 2000
    THEN
        RAISE EXCEPTION 'Refund text exceeds limit'
            USING ERRCODE = '22023';
    END IF;

    -- 4. Build canonical idempotency payload.

    v_payload := pg_catalog.jsonb_build_object(
        'operation', 'refund_v1',
        'actor_user_id', v_actor,
        'household_id', p_household_id,
        'original_transaction_id',
            p_original_transaction_id,
        'amount', p_amount::NUMERIC(18,2),
        'occurred_on', p_occurred_on,
        'description', v_description,
        'notes', v_notes
    );

    -- 5. Detect identical retries and key conflicts.

    v_transaction_id :=
        private.find_existing_ledger_transaction(
            p_household_id,
            p_idempotency_key,
            v_payload
        );

    IF v_transaction_id IS NOT NULL THEN
        RETURN v_transaction_id;
    END IF;

    -- 6. Locate the original financial operation.

    SELECT
        t.kind,
        t.amount,
        t.occurred_on
    INTO
        v_original_kind,
        v_original_amount,
        v_original_date
    FROM public.transactions t
    WHERE t.id = p_original_transaction_id
      AND t.household_id = p_household_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Original transaction not found'
            USING ERRCODE = '22023';
    END IF;

    -- Only original purchases are refundable.

    IF v_original_kind NOT IN (
        'expense',
        'credit_charge'
    ) THEN
        RAISE EXCEPTION
            'Transaction type does not support refund'
            USING ERRCODE = '22023';
    END IF;

    IF p_occurred_on < v_original_date THEN
        RAISE EXCEPTION
            'Refund cannot precede original transaction'
            USING ERRCODE = '22023';
    END IF;

    -- 7. Verify that the original expense has
    -- exactly one ledger movement.

    SELECT COUNT(*)
    INTO v_movement_count
    FROM public.account_movements m
    WHERE m.household_id = p_household_id
      AND m.transaction_id = p_original_transaction_id;

    IF v_movement_count <> 1 THEN
        RAISE EXCEPTION
            'Original transaction has invalid movements'
            USING ERRCODE = '23514';
    END IF;

    SELECT
        m.account_id,
        m.amount_delta
    INTO
        v_account_id,
        v_original_delta
    FROM public.account_movements m
    WHERE m.household_id = p_household_id
      AND m.transaction_id = p_original_transaction_id;

    -- 8. Lock the original account.
    -- All posting functions must follow
    -- account-level locking before balance checks.

    SELECT a.kind, a.status
    INTO v_account_kind, v_account_status
    FROM public.accounts a
    WHERE a.id = v_account_id
      AND a.household_id = p_household_id
    FOR UPDATE;

    IF NOT FOUND OR v_account_status <> 'active' THEN
        RAISE EXCEPTION 'Refund account is unavailable'
            USING ERRCODE = '22023';
    END IF;

    -- 9. Lock the original transaction.
    -- Concurrent partial refunds must be serialized.

    PERFORM 1
    FROM public.transactions t
    WHERE t.id = p_original_transaction_id
      AND t.household_id = p_household_id
    FOR UPDATE;

    -- 10. Verify original ledger direction.

    IF v_original_kind = 'expense' THEN

        IF v_account_kind NOT IN (
            'bank', 'cash', 'savings'
        )
        OR v_original_delta <> -v_original_amount
        THEN
            RAISE EXCEPTION
                'Original expense ledger is inconsistent'
                USING ERRCODE = '23514';
        END IF;

        -- Refund increases available money.
        v_refund_delta := p_amount;

    ELSIF v_original_kind = 'credit_charge' THEN

        IF v_account_kind <> 'credit_card'
           OR v_original_delta <> v_original_amount
        THEN
            RAISE EXCEPTION
                'Original credit ledger is inconsistent'
                USING ERRCODE = '23514';
        END IF;

        -- Refund decreases outstanding card principal.
        v_refund_delta := -p_amount;
    END IF;

    -- 11. Calculate previously refunded amount.

    SELECT COALESCE(SUM(t.amount), 0)
    INTO v_already_refunded
    FROM public.transactions t
    WHERE t.household_id = p_household_id
      AND t.kind = 'refund'
      AND t.refunded_transaction_id =
          p_original_transaction_id;

    v_refundable_amount :=
        v_original_amount - v_already_refunded;

    IF v_refundable_amount < p_amount THEN
        RAISE EXCEPTION
            'Refund exceeds remaining refundable amount'
            USING ERRCODE = '23514';
    END IF;

    -- 12. For credit cards, prevent the refund
    -- from creating negative outstanding principal.

    IF v_account_kind = 'credit_card' THEN

        SELECT COALESCE(SUM(m.amount_delta), 0)
        INTO v_current_balance
        FROM public.account_movements m
        WHERE m.household_id = p_household_id
          AND m.account_id = v_account_id;


        IF v_current_balance < p_amount THEN
            RAISE EXCEPTION
                'Refund exceeds current credit principal'
                USING ERRCODE = '23514';
        END IF;

        -- Verify that reducing credit principal
        -- does not create a negative balance
        -- on the refund date or any later date.

        PERFORM private.assert_nonnegative_account_timeline(
            p_household_id,
            v_account_id,
            p_occurred_on,
            -p_amount
        );

    END IF;

    -- 13. Insert refund transaction.
    -- The original reference preserves expense linkage.

    INSERT INTO public.transactions (
        household_id,
        kind,
        amount,
        occurred_on,
        description,
        notes,
        refunded_transaction_id,
        idempotency_key,
        request_fingerprint,
        created_by
    )
    VALUES (
        p_household_id,
        'refund',
        p_amount,
        p_occurred_on,
        v_description,
        v_notes,
        p_original_transaction_id,
        p_idempotency_key,
        private.ledger_request_fingerprint(v_payload),
        v_actor
    )
    RETURNING id INTO v_transaction_id;

    -- 14. Post the matching ledger movement.

    INSERT INTO public.account_movements (
        household_id,
        transaction_id,
        account_id,
        amount_delta
    )
    VALUES (
        p_household_id,
        v_transaction_id,
        v_account_id,
        v_refund_delta
    );

    RETURN v_transaction_id;
END;
$$;

REVOKE ALL
ON FUNCTION private.post_refund_internal(
    UUID, UUID, NUMERIC, DATE, TEXT, TEXT, TEXT
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION private.post_refund_internal(
    UUID, UUID, NUMERIC, DATE, TEXT, TEXT, TEXT
)
TO authenticated;


-- =========================================================
-- PUBLIC REFUND RPC
-- =========================================================

CREATE FUNCTION public.post_refund(
    p_household_id UUID,
    p_original_transaction_id UUID,
    p_amount NUMERIC,
    p_occurred_on DATE,
    p_idempotency_key TEXT,
    p_description TEXT DEFAULT NULL,
    p_notes TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE SQL
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
    SELECT private.post_refund_internal(
        p_household_id,
        p_original_transaction_id,
        p_amount,
        p_occurred_on,
        p_idempotency_key,
        p_description,
        p_notes
    );
$$;

REVOKE ALL
ON FUNCTION public.post_refund(
    UUID, UUID, NUMERIC, DATE, TEXT, TEXT, TEXT
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.post_refund(
    UUID, UUID, NUMERIC, DATE, TEXT, TEXT, TEXT
)
TO authenticated;



-- =========================================================
-- STEP 10: HISTORICAL NONNEGATIVE BALANCE GUARD
-- =========================================================

-- Called while the target account is locked.
-- Validates a proposed negative ledger movement.
--
-- Checks:
-- 1. End-of-day balance on the transaction date.
-- 2. Every subsequent end-of-day balance.
--
-- Applies to liquid accounts and credit principal.
-- Credit-limit ceilings require a separate guard.

CREATE FUNCTION private.assert_nonnegative_account_timeline(
    p_household_id UUID,
    p_account_id UUID,
    p_occurred_on DATE,
    p_amount_delta NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    v_min_balance NUMERIC;
BEGIN
    IF p_household_id IS NULL
       OR p_account_id IS NULL
       OR p_occurred_on IS NULL
       OR p_amount_delta IS NULL
       OR p_amount_delta >= 0
       OR p_amount_delta <>
          pg_catalog.round(p_amount_delta, 2)
    THEN
        RAISE EXCEPTION
            'Invalid historical balance check parameters'
            USING ERRCODE = '22023';
    END IF;

    -- Calculate end-of-day balances from the full ledger.

    WITH daily_movements AS (
        SELECT
            t.occurred_on,
            SUM(m.amount_delta) AS daily_delta

        FROM public.account_movements m

        JOIN public.transactions t
            ON t.id = m.transaction_id
           AND t.household_id = m.household_id

        WHERE m.household_id = p_household_id
          AND m.account_id = p_account_id

        GROUP BY t.occurred_on
    ),

    running_balances AS (
        SELECT
            occurred_on,

            SUM(daily_delta) OVER (
                ORDER BY occurred_on
                ROWS BETWEEN UNBOUNDED PRECEDING
                         AND CURRENT ROW
            ) AS balance

        FROM daily_movements
    ),

    balance_bounds AS (
        SELECT
            COALESCE(
                (
                    SELECT r.balance
                    FROM running_balances r
                    WHERE r.occurred_on <= p_occurred_on
                    ORDER BY r.occurred_on DESC
                    LIMIT 1
                ),
                0
            ) AS balance_on_date,

            (
                SELECT MIN(r.balance)
                FROM running_balances r
                WHERE r.occurred_on > p_occurred_on
            ) AS min_future_balance
    )

    SELECT LEAST(
        balance_on_date,
        COALESCE(
            min_future_balance,
            balance_on_date
        )
    )
    INTO v_min_balance
    FROM balance_bounds;

    -- The proposed delta affects the transaction date
    -- and all subsequent dates.

    IF v_min_balance + p_amount_delta < 0 THEN
        RAISE EXCEPTION
            'Insufficient balance on transaction date or later'
            USING ERRCODE = '23514';
    END IF;
END;
$$;

REVOKE ALL
ON FUNCTION private.assert_nonnegative_account_timeline(
    UUID, UUID, DATE, NUMERIC
)
FROM PUBLIC, anon, authenticated;



-- =========================================================
-- STEP 11: HISTORICAL CREDIT LIMIT GUARD
-- =========================================================

-- Called after locking the credit card account.
-- Validates a proposed credit charge against
-- all applicable historical and future limits.

CREATE FUNCTION private.assert_credit_limit_timeline(
    p_household_id UUID,
    p_account_id UUID,
    p_occurred_on DATE,
    p_amount_delta NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    v_breach_date DATE;
    v_projected_debt NUMERIC;
    v_applicable_limit NUMERIC;
BEGIN
    -- 1. Validate parameters.

    IF p_household_id IS NULL
       OR p_account_id IS NULL
       OR p_occurred_on IS NULL
       OR p_amount_delta IS NULL
       OR p_amount_delta <= 0
       OR p_amount_delta <>
          pg_catalog.round(p_amount_delta, 2)
    THEN
        RAISE EXCEPTION
            'Invalid credit timeline parameters'
            USING ERRCODE = '22023';
    END IF;

    -- 2. Confirm credit card account type.

    IF NOT EXISTS (
        SELECT 1
        FROM public.accounts a
        WHERE a.id = p_account_id
          AND a.household_id = p_household_id
          AND a.kind = 'credit_card'
    ) THEN
        RAISE EXCEPTION
            'Credit card account required'
            USING ERRCODE = '22023';
    END IF;

    -- 3. Reconstruct historical daily movements.
    -- Include all movement dates for running totals.

    WITH daily_movements AS (
        SELECT
            t.occurred_on,
            SUM(m.amount_delta) AS daily_delta

        FROM public.account_movements m

        JOIN public.transactions t
          ON t.id = m.transaction_id
         AND t.household_id = m.household_id

        WHERE m.household_id = p_household_id
          AND m.account_id = p_account_id

        GROUP BY t.occurred_on
    ),

    -- 4. Include purchase date, movement dates
    -- and future credit limit changes.

    event_dates AS (
        SELECT p_occurred_on AS check_date

        UNION

        SELECT occurred_on
        FROM daily_movements

        UNION

        SELECT cl.effective_on
        FROM public.credit_limit_history cl
        WHERE cl.household_id = p_household_id
          AND cl.account_id = p_account_id
          AND cl.effective_on >= p_occurred_on
    ),

    -- 5. Find the applicable credit limit
    -- for every relevant date.

    timeline AS (
        SELECT
            d.check_date,

            COALESCE(dm.daily_delta, 0)
                AS daily_delta,

            (
                SELECT cl.limit_amount
                FROM public.credit_limit_history cl

                WHERE cl.household_id = p_household_id
                  AND cl.account_id = p_account_id
                  AND cl.effective_on <= d.check_date

                ORDER BY
                    cl.effective_on DESC,
                    cl.recorded_at DESC,
                    cl.id DESC

                LIMIT 1
            ) AS applicable_limit

        FROM event_dates d

        LEFT JOIN daily_movements dm
          ON dm.occurred_on = d.check_date
    ),

    -- 6. Calculate projected principal.
    -- New charge affects its date and all later dates.

    running_balances AS (
        SELECT
            check_date,

            SUM(daily_delta) OVER (
                ORDER BY check_date
                ROWS BETWEEN UNBOUNDED PRECEDING
                         AND CURRENT ROW
            )
            +
            CASE
                WHEN check_date >= p_occurred_on
                THEN p_amount_delta
                ELSE 0
            END AS projected_debt,

            applicable_limit

        FROM timeline
    )

    -- 7. Find the first limit violation.

    SELECT
        check_date,
        projected_debt,
        applicable_limit
    INTO
        v_breach_date,
        v_projected_debt,
        v_applicable_limit

    FROM running_balances

    WHERE check_date >= p_occurred_on
      AND (
          applicable_limit IS NULL
          OR projected_debt > applicable_limit
          OR projected_debt < 0
      )

    ORDER BY check_date
    LIMIT 1;

    -- 8. Reject the new purchase if a violation exists.

    IF FOUND THEN
        RAISE EXCEPTION
            'Credit limit violation on %. Projected debt: %, limit: %',
            v_breach_date,
            v_projected_debt,
            v_applicable_limit
            USING ERRCODE = '23514';
    END IF;
END;
$$;

-- Internal helper, not directly executable
-- by API user roles.

REVOKE ALL
ON FUNCTION private.assert_credit_limit_timeline(
    UUID, UUID, DATE, NUMERIC
)
FROM PUBLIC, anon, authenticated;



-- =========================================================
-- STEP 12: VALIDATE CREDIT LIMIT HISTORY INSERTS
-- =========================================================

-- Replace the existing trigger function.
-- The original trigger remains attached.

CREATE OR REPLACE FUNCTION private.validate_credit_limit_account()
RETURNS TRIGGER
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NEW.effective_on < DATE '2026-11-01' THEN
        RAISE EXCEPTION
            'Credit limit date precedes budget start'
            USING ERRCODE = '22023';
    END IF;

    -- Lock account before changing its credit limit.
    -- Ledger posting functions use the same account lock.

    PERFORM 1
    FROM public.accounts a
    WHERE a.id = NEW.account_id
      AND a.household_id = NEW.household_id
      AND a.kind = 'credit_card'
      AND a.status = 'active'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Active credit card account required'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;


-- Validate the complete credit history after insertion.
-- The new limit is included in the calculation.

CREATE FUNCTION private.validate_credit_limit_timeline()
RETURNS TRIGGER
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_breach_date DATE;
    v_debt NUMERIC;
    v_limit NUMERIC;
BEGIN

    WITH daily_movements AS (
        SELECT
            t.occurred_on AS movement_date,
            SUM(m.amount_delta) AS daily_delta

        FROM public.account_movements m

        JOIN public.transactions t
          ON t.id = m.transaction_id
         AND t.household_id = m.household_id

        WHERE m.household_id = NEW.household_id
          AND m.account_id = NEW.account_id

        GROUP BY t.occurred_on
    ),

    event_dates AS (
        SELECT movement_date AS check_date
        FROM daily_movements

        UNION

        SELECT effective_on AS check_date
        FROM public.credit_limit_history
        WHERE household_id = NEW.household_id
          AND account_id = NEW.account_id
    ),

    daily_timeline AS (
        SELECT
            d.check_date,

            SUM(COALESCE(dm.daily_delta, 0))
                OVER (
                    ORDER BY d.check_date
                    ROWS BETWEEN UNBOUNDED PRECEDING
                             AND CURRENT ROW
                ) AS outstanding_debt,

            (
                SELECT cl.limit_amount
                FROM public.credit_limit_history cl
                WHERE cl.household_id = NEW.household_id
                  AND cl.account_id = NEW.account_id
                  AND cl.effective_on <= d.check_date
                ORDER BY
                    cl.effective_on DESC,
                    cl.recorded_at DESC,
                    cl.id DESC
                LIMIT 1
            ) AS applicable_limit

        FROM event_dates d

        LEFT JOIN daily_movements dm
          ON dm.movement_date = d.check_date
    )

    SELECT
        check_date,
        outstanding_debt,
        applicable_limit
    INTO
        v_breach_date,
        v_debt,
        v_limit

    FROM daily_timeline

    WHERE outstanding_debt < 0
       OR outstanding_debt > COALESCE(applicable_limit, 0)

    ORDER BY check_date
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'Credit limit history violation on %. Debt: %, limit: %',
            v_breach_date,
            v_debt,
            v_limit
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

-- No direct execution for API roles.

REVOKE ALL
ON FUNCTION private.validate_credit_limit_timeline()
FROM PUBLIC, anon, authenticated;


-- Run after the new limit is inserted.
-- Any violation rolls back the entire insertion.

CREATE TRIGGER enforce_credit_limit_timeline
AFTER INSERT ON public.credit_limit_history
FOR EACH ROW
EXECUTE FUNCTION private.validate_credit_limit_timeline();
