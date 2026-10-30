
-- =========================================================
-- FAMILY BUDGET - INITIAL AUTH SCHEMA
-- Migration: 20261029182639
-- =========================================================

-- 1. PRIVATE SCHEMA

CREATE SCHEMA IF NOT EXISTS private;

REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO authenticated;


-- 2. USER PROFILES

CREATE TABLE public.profiles (
    id UUID PRIMARY KEY
        REFERENCES auth.users(id) ON DELETE CASCADE,

    display_name TEXT,

    locale TEXT NOT NULL DEFAULT 'bg'
        CHECK (locale IN ('bg', 'en')),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- 3. HOUSEHOLDS

CREATE TABLE public.households (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    name TEXT NOT NULL
        CHECK (char_length(btrim(name)) BETWEEN 1 AND 100),

    currency TEXT NOT NULL DEFAULT 'EUR'
        CHECK (currency = 'EUR'),

    timezone TEXT NOT NULL DEFAULT 'Europe/Sofia'
        CHECK (timezone = 'Europe/Sofia'),

    created_by UUID NOT NULL
        REFERENCES auth.users(id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    archived_at TIMESTAMPTZ
);


-- 4. HOUSEHOLD MEMBERS

CREATE TABLE public.household_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    household_id UUID NOT NULL
        REFERENCES public.households(id) ON DELETE RESTRICT,

    user_id UUID NOT NULL
        REFERENCES public.profiles(id) ON DELETE RESTRICT,

    role TEXT NOT NULL
        CHECK (role IN ('owner', 'member')),

    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'inactive')),

    joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (household_id, user_id)
);

CREATE INDEX household_members_user_idx
    ON public.household_members(user_id, status);

CREATE INDEX household_members_household_idx
    ON public.household_members(household_id, status);


-- 5. AUDIT LOG

CREATE TABLE public.audit_log (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    household_id UUID NOT NULL
        REFERENCES public.households(id) ON DELETE RESTRICT,

    actor_user_id UUID,

    entity_type TEXT NOT NULL,
    entity_id UUID NOT NULL,

    action TEXT NOT NULL
        CHECK (action IN ('insert', 'update', 'delete')),

    before_data JSONB,
    after_data JSONB,

    occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX audit_log_household_time_idx
    ON public.audit_log(household_id, occurred_at DESC);


-- 6. HOUSEHOLD ACCESS HELPERS

CREATE FUNCTION private.is_household_member(
    p_household_id UUID
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.household_members hm
        WHERE hm.household_id = p_household_id
          AND hm.user_id = (SELECT auth.uid())
          AND hm.status = 'active'
    );
$$;

CREATE FUNCTION private.is_household_owner(
    p_household_id UUID
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.household_members hm
        WHERE hm.household_id = p_household_id
          AND hm.user_id = (SELECT auth.uid())
          AND hm.role = 'owner'
          AND hm.status = 'active'
    );
$$;

REVOKE ALL ON FUNCTION
    private.is_household_member(UUID) FROM PUBLIC;

REVOKE ALL ON FUNCTION
    private.is_household_owner(UUID) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    private.is_household_member(UUID) TO authenticated;

GRANT EXECUTE ON FUNCTION
    private.is_household_owner(UUID) TO authenticated;


-- 7. AUTOMATIC PROFILE CREATION

CREATE FUNCTION private.handle_new_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    INSERT INTO public.profiles (id)
    VALUES (NEW.id)
    ON CONFLICT (id) DO NOTHING;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION
    private.handle_new_auth_user() FROM PUBLIC;

CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION private.handle_new_auth_user();

-- Backfill users created before this migration.

INSERT INTO public.profiles (id)
SELECT id
FROM auth.users
ON CONFLICT (id) DO NOTHING;


-- 8. UPDATED_AT TRIGGER

CREATE FUNCTION private.touch_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION
    private.touch_updated_at() FROM PUBLIC;

CREATE TRIGGER profiles_updated_at
BEFORE UPDATE ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION private.touch_updated_at();

CREATE TRIGGER households_updated_at
BEFORE UPDATE ON public.households
FOR EACH ROW
EXECUTE FUNCTION private.touch_updated_at();

CREATE TRIGGER household_members_updated_at
BEFORE UPDATE ON public.household_members
FOR EACH ROW
EXECUTE FUNCTION private.touch_updated_at();


-- 9. AUDIT TRIGGER

CREATE FUNCTION private.audit_household_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_before JSONB;
    v_after JSONB;
    v_record JSONB;
    v_household_id UUID;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_after := to_jsonb(NEW);
        v_record := v_after;

    ELSIF TG_OP = 'UPDATE' THEN
        v_before := to_jsonb(OLD);
        v_after := to_jsonb(NEW);
        v_record := v_after;

    ELSE
        v_before := to_jsonb(OLD);
        v_record := v_before;
    END IF;

    IF TG_TABLE_NAME = 'households' THEN
        v_household_id := (v_record->>'id')::UUID;
    ELSE
        v_household_id := (v_record->>'household_id')::UUID;
    END IF;

    INSERT INTO public.audit_log (
        household_id,
        actor_user_id,
        entity_type,
        entity_id,
        action,
        before_data,
        after_data
    )
    VALUES (
        v_household_id,
        auth.uid(),
        TG_TABLE_NAME,
        (v_record->>'id')::UUID,
        lower(TG_OP),
        v_before,
        v_after
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION
    private.audit_household_change() FROM PUBLIC;

CREATE TRIGGER audit_households
AFTER INSERT OR UPDATE OR DELETE
ON public.households
FOR EACH ROW
EXECUTE FUNCTION private.audit_household_change();

CREATE TRIGGER audit_household_members
AFTER INSERT OR UPDATE OR DELETE
ON public.household_members
FOR EACH ROW
EXECUTE FUNCTION private.audit_household_change();


-- 10. ENABLE ROW LEVEL SECURITY

ALTER TABLE public.profiles
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.households
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.household_members
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.audit_log
    ENABLE ROW LEVEL SECURITY;


-- 11. EXPLICIT TABLE PRIVILEGES

REVOKE ALL ON public.profiles,
    public.households,
    public.household_members,
    public.audit_log
FROM anon, authenticated;

GRANT SELECT ON public.profiles
    TO authenticated;

GRANT UPDATE (display_name, locale)
    ON public.profiles TO authenticated;

GRANT SELECT ON public.households
    TO authenticated;

GRANT SELECT ON public.household_members
    TO authenticated;

GRANT SELECT ON public.audit_log
    TO authenticated;


-- 12. PROFILES POLICIES

CREATE POLICY profiles_select_own
ON public.profiles
FOR SELECT
TO authenticated
USING (
    id = (SELECT auth.uid())
);

CREATE POLICY profiles_update_own
ON public.profiles
FOR UPDATE
TO authenticated
USING (
    id = (SELECT auth.uid())
)
WITH CHECK (
    id = (SELECT auth.uid())
);


-- 13. HOUSEHOLD POLICIES

CREATE POLICY households_select_member
ON public.households
FOR SELECT
TO authenticated
USING (
    private.is_household_member(id)
);


-- 14. HOUSEHOLD MEMBERSHIP POLICIES

CREATE POLICY household_members_select_member
ON public.household_members
FOR SELECT
TO authenticated
USING (
    private.is_household_member(household_id)
);


-- 15. AUDIT POLICIES

CREATE POLICY audit_log_select_owner
ON public.audit_log
FOR SELECT
TO authenticated
USING (
    private.is_household_owner(household_id)
);

-- Direct INSERT/UPDATE/DELETE on households,
-- household_members and audit_log is not granted.
-- Owner onboarding will use a controlled workflow.
-- Financial tables will be added in later migrations.
