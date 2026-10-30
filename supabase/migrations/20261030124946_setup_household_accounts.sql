-- First-run setup of the five canonical household accounts.
-- No balances, debts or credit limits are created here.

CREATE FUNCTION public.setup_household_accounts(
    p_household_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_user_id uuid;
    v_household_id uuid;
    v_account_count integer;
    v_accounts jsonb;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required'
            USING ERRCODE = '28000';
    END IF;

    IF p_household_id IS NULL THEN
        RAISE EXCEPTION 'Household ID is required'
            USING ERRCODE = '22023';
    END IF;

    -- Verify active Owner membership.
    -- Lock the household to serialize concurrent setup calls.
    SELECT h.id
    INTO v_household_id
    FROM public.households AS h
    JOIN public.household_members AS hm
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

    -- Reject conflicting existing account configurations.
    -- Never overwrite or reactivate an existing account.
    IF EXISTS (
        SELECT 1
        FROM public.accounts AS a
        JOIN (
            VALUES
                ('revolut', 'bank'),
                ('cash', 'cash'),
                ('savings', 'savings'),
                ('biala', 'credit_card'),
                ('a1', 'credit_card')
        ) AS expected(code, kind)
            ON expected.code = a.code
        WHERE a.household_id = v_household_id
          AND (
              a.kind <> expected.kind
              OR a.currency <> 'EUR'
              OR a.status <> 'active'
              OR a.closed_at IS NOT NULL
          )
    ) THEN
        RAISE EXCEPTION
            'Existing account configuration requires review'
            USING ERRCODE = '23514';
    END IF;

    -- Create missing accounts only.
    -- All inserts belong to the same database transaction.
    INSERT INTO public.accounts (
        household_id,
        code,
        name,
        kind,
        currency,
        status,
        created_by
    )
    VALUES
        (
            v_household_id,
            'revolut',
            'Revolut',
            'bank',
            'EUR',
            'active',
            v_user_id
        ),
        (
            v_household_id,
            'cash',
            'Cash',
            'cash',
            'EUR',
            'active',
            v_user_id
        ),
        (
            v_household_id,
            'savings',
            'Savings',
            'savings',
            'EUR',
            'active',
            v_user_id
        ),
        (
            v_household_id,
            'biala',
            'Бяла карта',
            'credit_card',
            'EUR',
            'active',
            v_user_id
        ),
        (
            v_household_id,
            'a1',
            'A1',
            'credit_card',
            'EUR',
            'active',
            v_user_id
        )
    ON CONFLICT (household_id, code)
    DO NOTHING;

    -- Confirm that all five canonical accounts exist.
    SELECT
        count(*)::integer,
        jsonb_object_agg(a.code, a.id)
    INTO
        v_account_count,
        v_accounts
    FROM public.accounts AS a
    WHERE a.household_id = v_household_id
      AND a.code IN (
          'revolut',
          'cash',
          'savings',
          'biala',
          'a1'
      );

    IF v_account_count <> 5 THEN
        RAISE EXCEPTION 'Household account setup incomplete'
            USING ERRCODE = 'P0001';
    END IF;

    RETURN v_accounts;
END;
$function$;

-- Only authenticated users may call the RPC.
-- The function itself verifies Owner membership.
REVOKE ALL ON FUNCTION
    public.setup_household_accounts(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
    public.setup_household_accounts(uuid)
TO authenticated;

COMMENT ON FUNCTION
    public.setup_household_accounts(uuid)
IS
    'Idempotent creation of five household accounts. '
    'Requires active Owner membership. '
    'Does not initialize financial balances.';