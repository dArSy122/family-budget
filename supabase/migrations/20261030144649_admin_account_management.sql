-- Dynamic financial account management.
-- Part 1: metadata, Owner authorization, account creation.
-- Existing accounts and ledger history remain unchanged.

-- Separate archiving from closing.
ALTER TABLE public.accounts
ADD COLUMN archived_at timestamptz;

-- Stable identifier for retry-safe account creation.
ALTER TABLE public.accounts
ADD COLUMN creation_request_id uuid;

CREATE UNIQUE INDEX accounts_creation_request_uidx
ON public.accounts (
    household_id,
    creation_request_id
)
WHERE creation_request_id IS NOT NULL;


-- Shared authorization helper for administrative RPCs.
CREATE FUNCTION private.require_household_owner(
    p_household_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_user_id uuid;
    v_household_id uuid;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required'
            USING ERRCODE = '28000';
    END IF;

    IF p_household_id IS NULL THEN
        RAISE EXCEPTION 'Household ID required'
            USING ERRCODE = '22023';
    END IF;

    -- Serialize administrative operations per household.
    SELECT h.id
    INTO v_household_id
    FROM public.households h
    JOIN public.household_members hm
        ON hm.household_id = h.id
    WHERE h.id = p_household_id
      AND h.archived_at IS NULL
      AND hm.user_id = v_user_id
      AND hm.role = 'owner'
      AND hm.status = 'active'
    FOR UPDATE OF h;

    IF v_household_id IS NULL THEN
        RAISE EXCEPTION 'Active household Owner required'
            USING ERRCODE = '42501';
    END IF;

    RETURN v_user_id;
END;
$function$;

REVOKE ALL ON FUNCTION
    private.require_household_owner(uuid)
FROM PUBLIC, anon, authenticated;


-- Create a new account through the application.
CREATE FUNCTION public.create_household_account(
    p_household_id uuid,
    p_name text,
    p_kind text,
    p_request_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_user_id uuid;
    v_name text;
    v_account_id uuid;
    v_existing_name text;
    v_existing_kind text;
    v_code text;
BEGIN
    -- Authorization is mandatory for every request.
    v_user_id :=
        private.require_household_owner(p_household_id);

    v_name := NULLIF(btrim(p_name), '');

    IF v_name IS NULL
       OR char_length(v_name) > 100 THEN
        RAISE EXCEPTION 'Invalid account name'
            USING ERRCODE = '22023';
    END IF;

    IF p_kind IS NULL
       OR p_kind NOT IN (
           'bank',
           'cash',
           'savings',
           'credit_card'
       ) THEN
        RAISE EXCEPTION 'Invalid account type'
            USING ERRCODE = '22023';
    END IF;

    IF p_request_id IS NULL THEN
        RAISE EXCEPTION 'Request ID required'
            USING ERRCODE = '22023';
    END IF;

    -- Idempotency: the same request must not create
    -- a second account.
    SELECT
        a.id,
        a.name,
        a.kind
    INTO
        v_account_id,
        v_existing_name,
        v_existing_kind
    FROM public.accounts a
    WHERE a.household_id = p_household_id
      AND a.creation_request_id = p_request_id
    FOR UPDATE;

    IF v_account_id IS NOT NULL THEN

        IF v_existing_name <> v_name
           OR v_existing_kind <> p_kind THEN
            RAISE EXCEPTION
                'Idempotency key reused with different data'
                USING ERRCODE = '23505';
        END IF;

        RETURN v_account_id;
    END IF;

    -- Generate an internal ASCII account code.
    -- Users do not need to enter technical identifiers.
    v_code := 'acct_' ||
        left(
            replace(gen_random_uuid()::text, '-', ''),
            26
        );

    INSERT INTO public.accounts (
        household_id,
        code,
        name,
        kind,
        currency,
        status,
        created_by,
        creation_request_id
    )
    VALUES (
        p_household_id,
        v_code,
        v_name,
        p_kind,
        'EUR',
        'active',
        v_user_id,
        p_request_id
    )
    RETURNING id INTO v_account_id;

    RETURN v_account_id;
END;
$function$;

-- Prevent anonymous execution.
REVOKE ALL ON FUNCTION
    public.create_household_account(
        uuid, text, text, uuid
    )
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
    public.create_household_account(
        uuid, text, text, uuid
    )
TO authenticated;

COMMENT ON FUNCTION
    public.create_household_account(
        uuid, text, text, uuid
    )
IS
    'Owner-only account creation with idempotency. '
    'Financial balances must be initialized separately.';

    -- Owner-only account metadata management.
-- Actions: rename, archive, restore.
-- No financial ledger entries are modified.

CREATE FUNCTION public.manage_household_account(
    p_household_id uuid,
    p_account_id uuid,
    p_action text,
    p_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_account public.accounts%ROWTYPE;
    v_name text;
BEGIN
    -- Verify Owner and serialize administrative operations.
    PERFORM private.require_household_owner(p_household_id);

    IF p_account_id IS NULL THEN
        RAISE EXCEPTION 'Account ID required'
            USING ERRCODE = '22023';
    END IF;

    IF p_action IS NULL
       OR p_action NOT IN ('rename', 'archive', 'restore') THEN
        RAISE EXCEPTION 'Invalid account action'
            USING ERRCODE = '22023';
    END IF;

    -- Lock the account to coordinate with Ledger operations.
    SELECT a.*
    INTO v_account
    FROM public.accounts AS a
    WHERE a.id = p_account_id
      AND a.household_id = p_household_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account not found'
            USING ERRCODE = '42501';
    END IF;

    IF p_action = 'rename' THEN

        v_name := NULLIF(btrim(p_name), '');

        IF v_name IS NULL
           OR char_length(v_name) > 100 THEN
            RAISE EXCEPTION 'Invalid account name'
                USING ERRCODE = '22023';
        END IF;

        IF v_account.name IS DISTINCT FROM v_name THEN
            UPDATE public.accounts
            SET name = v_name,
                updated_at = now()
            WHERE id = p_account_id
              AND household_id = p_household_id
            RETURNING * INTO v_account;
        END IF;

    ELSIF p_action = 'archive' THEN

        IF v_account.archived_at IS NULL THEN
            UPDATE public.accounts
            SET archived_at = now(),
                updated_at = now()
            WHERE id = p_account_id
              AND household_id = p_household_id
            RETURNING * INTO v_account;
        END IF;

    ELSIF p_action = 'restore' THEN

        IF v_account.archived_at IS NOT NULL THEN
            UPDATE public.accounts
            SET archived_at = NULL,
                updated_at = now()
            WHERE id = p_account_id
              AND household_id = p_household_id
            RETURNING * INTO v_account;
        END IF;

    END IF;

    RETURN jsonb_build_object(
        'account_id', v_account.id,
        'name', v_account.name,
        'status', v_account.status,
        'archived_at', v_account.archived_at
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.manage_household_account(
        uuid, uuid, text, text
    )
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
    public.manage_household_account(
        uuid, uuid, text, text
    )
TO authenticated;

COMMENT ON FUNCTION
    public.manage_household_account(
        uuid, uuid, text, text
    )
IS
    'Owner-only account rename, archive and restore. '
    'Preserves financial ledger and audit history.';


    -- Owner-only account closure.
-- Requires zero balance and no future-dated movements.
-- Financial and audit history remain intact.

CREATE FUNCTION public.close_household_account(
    p_household_id uuid,
    p_account_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_account public.accounts%ROWTYPE;
    v_balance numeric;
    v_future_movements bigint;
BEGIN
    -- Require active household Owner.
    -- Lock household to serialize administrative changes.
    PERFORM private.require_household_owner(p_household_id);

    IF p_account_id IS NULL THEN
        RAISE EXCEPTION 'Account ID required'
            USING ERRCODE = '22023';
    END IF;

    -- Lock account against concurrent Ledger operations.
    SELECT a.*
    INTO v_account
    FROM public.accounts AS a
    WHERE a.id = p_account_id
      AND a.household_id = p_household_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account not found'
            USING ERRCODE = '42501';
    END IF;

    -- Repeated closure is idempotent.
    IF v_account.status = 'closed' THEN
        RETURN jsonb_build_object(
            'account_id', v_account.id,
            'status', v_account.status,
            'closed_at', v_account.closed_at,
            'already_closed', true
        );
    END IF;

    -- Calculate the actual Ledger balance.
    -- Credit card debt is represented as a positive balance.
    SELECT COALESCE(SUM(m.amount_delta), 0)
    INTO v_balance
    FROM public.account_movements AS m
    WHERE m.household_id = p_household_id
      AND m.account_id = p_account_id;

    IF v_balance <> 0 THEN
        RAISE EXCEPTION
            'Account cannot be closed with nonzero balance: %',
            v_balance
            USING ERRCODE = '23514';
    END IF;

    -- Prevent closing accounts with future-dated postings.
    SELECT COUNT(*)
    INTO v_future_movements
    FROM public.account_movements AS m
    JOIN public.transactions AS t
        ON t.id = m.transaction_id
       AND t.household_id = m.household_id
    WHERE m.household_id = p_household_id
      AND m.account_id = p_account_id
      AND t.occurred_on >
          (now() AT TIME ZONE 'Europe/Sofia')::date;

    IF v_future_movements > 0 THEN
        RAISE EXCEPTION
            'Account has future-dated financial movements'
            USING ERRCODE = '23514';
    END IF;

    -- Close without deleting financial history.
    UPDATE public.accounts
    SET
        status = 'closed',
        closed_at = now(),
        updated_at = now()
    WHERE id = p_account_id
      AND household_id = p_household_id
    RETURNING * INTO v_account;

    RETURN jsonb_build_object(
        'account_id', v_account.id,
        'status', v_account.status,
        'closed_at', v_account.closed_at,
        'closing_balance', v_balance,
        'already_closed', false
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.close_household_account(uuid, uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
    public.close_household_account(uuid, uuid)
TO authenticated;

COMMENT ON FUNCTION
    public.close_household_account(uuid, uuid)
IS
    'Owner-only account closure requiring zero Ledger balance '
    'and no future-dated movements. '
    'Preserves transactions, movements and audit history.';