-- Fix account creation idempotency after account rename.
-- Original request data is read from immutable audit history.

CREATE OR REPLACE FUNCTION public.create_household_account(
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
    v_original_name text;
    v_original_kind text;
    v_code text;
BEGIN
    -- Verify active Owner and lock household.
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

    -- Check for a previously processed request.
    SELECT a.id
    INTO v_account_id
    FROM public.accounts AS a
    WHERE a.household_id = p_household_id
      AND a.creation_request_id = p_request_id
    FOR UPDATE;

    IF v_account_id IS NOT NULL THEN

        -- Retrieve the ORIGINAL creation parameters.
        -- Current account name may have changed.
        SELECT
            al.after_data ->> 'name',
            al.after_data ->> 'kind'
        INTO
            v_original_name,
            v_original_kind
        FROM public.audit_log AS al
        WHERE al.household_id = p_household_id
          AND al.entity_type = 'accounts'
          AND al.entity_id = v_account_id
          AND al.action = 'insert'
          AND al.after_data ->> 'creation_request_id'
              = p_request_id::text
        ORDER BY al.id
        LIMIT 1;

        -- Fail closed if the historical snapshot is missing.
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Original account creation audit missing'
                USING ERRCODE = '23514';
        END IF;

        -- Compare against original request, not current name.
        IF v_original_name IS DISTINCT FROM v_name
           OR v_original_kind IS DISTINCT FROM p_kind THEN
            RAISE EXCEPTION
                'Idempotency key reused with different data'
                USING ERRCODE = '23505';
        END IF;

        RETURN v_account_id;
    END IF;

    -- Create a new account.
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

REVOKE ALL ON FUNCTION
    public.create_household_account(
        uuid, text, text, uuid
    )
FROM PUBLIC, anon, authenticated;

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
    'Owner-only account creation. Idempotency compares '
    'the original immutable audit snapshot, not mutable '
    'account metadata.';