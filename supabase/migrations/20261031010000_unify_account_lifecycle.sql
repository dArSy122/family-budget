-- Migration 10: Unified account lifecycle.
--
-- Supported user-facing states:
-- active / closed
--
-- Supported administrative actions:
-- rename / close
--
-- Archive and restore are no longer allowed.
-- Preserve all accounts, financial history and audit records.

CREATE OR REPLACE FUNCTION public.manage_household_account(
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
    -- Require an active Owner.
    -- Serialize administrative operations per household.
    PERFORM private.require_household_owner(
        p_household_id
    );

    IF p_account_id IS NULL THEN
        RAISE EXCEPTION 'Account ID required'
            USING ERRCODE = '22023';
    END IF;

    -- Archive and restore are permanently disabled
    -- through this public RPC.
    IF p_action IS DISTINCT FROM 'rename' THEN
        RAISE EXCEPTION 'Invalid account action'
            USING ERRCODE = '22023';
    END IF;

    -- Lock the account against concurrent operations.
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

    -- Closed accounts cannot be renamed.
    IF v_account.status IS DISTINCT FROM 'active' THEN
        RAISE EXCEPTION 'Account is not active'
            USING ERRCODE = '23514';
    END IF;

    v_name := NULLIF(btrim(p_name), '');

    IF v_name IS NULL
       OR char_length(v_name) > 100 THEN
        RAISE EXCEPTION 'Invalid account name'
            USING ERRCODE = '22023';
    END IF;

    -- Avoid unnecessary updates and audit entries.
    IF v_account.name IS DISTINCT FROM v_name THEN
        UPDATE public.accounts
        SET name = v_name,
            updated_at = now()
        WHERE id = p_account_id
          AND household_id = p_household_id
        RETURNING * INTO v_account;
    END IF;

    RETURN jsonb_build_object(
        'account_id', v_account.id,
        'name', v_account.name,
        'status', v_account.status,
        'archived_at', v_account.archived_at
    );
END;
$function$;

-- Explicit execution permissions.

REVOKE ALL ON FUNCTION
    public.manage_household_account(
        uuid, uuid, text, text
    )
FROM PUBLIC, anon, authenticated;

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
    'Owner-only rename of active financial accounts. '
    'Archive and restore are disabled. '
    'Account closure is handled by close_household_account. '
    'Financial history and audit records are preserved.';