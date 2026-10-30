-- Household setup: authenticated first-run initialization.

CREATE FUNCTION public.setup_household(
    p_name text DEFAULT 'Family Budget'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_user_id uuid;
    v_profile_id uuid;
    v_household_id uuid;
    v_name text;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required'
            USING ERRCODE = '28000';
    END IF;

    -- Serialize setup requests for the same user.
    SELECT p.id
    INTO v_profile_id
    FROM public.profiles AS p
    WHERE p.id = v_user_id
    FOR UPDATE;

    IF v_profile_id IS NULL THEN
        RAISE EXCEPTION 'User profile not found'
            USING ERRCODE = 'P0001';
    END IF;

    -- Idempotent return for an existing active membership.
    SELECT hm.household_id
    INTO v_household_id
    FROM public.household_members AS hm
    JOIN public.households AS h
        ON h.id = hm.household_id
    WHERE hm.user_id = v_user_id
      AND hm.status = 'active'
      AND h.archived_at IS NULL
    ORDER BY hm.joined_at, hm.id
    LIMIT 1;

    IF v_household_id IS NOT NULL THEN
        RETURN v_household_id;
    END IF;

    -- Do not bypass inactive memberships or archived households.
    IF EXISTS (
        SELECT 1
        FROM public.household_members
        WHERE user_id = v_user_id
    ) OR EXISTS (
        SELECT 1
        FROM public.households
        WHERE created_by = v_user_id
    ) THEN
        RAISE EXCEPTION
            'Existing household association requires review'
            USING ERRCODE = 'P0001';
    END IF;

    v_name := NULLIF(btrim(p_name), '');

    IF v_name IS NULL
       OR char_length(v_name) > 100 THEN
        RAISE EXCEPTION 'Invalid household name'
            USING ERRCODE = '22023';
    END IF;

    -- Both inserts belong to the same database transaction.
    INSERT INTO public.households (
        name,
        currency,
        timezone,
        created_by
    )
    VALUES (
        v_name,
        'EUR',
        'Europe/Sofia',
        v_user_id
    )
    RETURNING id INTO v_household_id;

    INSERT INTO public.household_members (
        household_id,
        user_id,
        role,
        status
    )
    VALUES (
        v_household_id,
        v_user_id,
        'owner',
        'active'
    );

    RETURN v_household_id;
END;
$function$;

-- Restrict RPC execution to authenticated users.
REVOKE ALL ON FUNCTION public.setup_household(text)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.setup_household(text)
TO authenticated;