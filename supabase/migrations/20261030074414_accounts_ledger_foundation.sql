
-- =========================================================
-- FAMILY BUDGET - ACCOUNTS & LEDGER FOUNDATION
-- Migration: 20261030074414
-- Currency: EUR
-- =========================================================

-- 1. ACCOUNTS

CREATE TABLE public.accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    household_id UUID NOT NULL
        REFERENCES public.households(id) ON DELETE RESTRICT,

    code TEXT NOT NULL
        CHECK (code ~ '^[a-z0-9_]{2,32}$'),

    name TEXT NOT NULL
        CHECK (char_length(btrim(name)) BETWEEN 1 AND 100),

    kind TEXT NOT NULL
        CHECK (kind IN (
            'bank',
            'cash',
            'savings',
            'credit_card'
        )),

    currency TEXT NOT NULL DEFAULT 'EUR'
        CHECK (currency = 'EUR'),

    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'closed')),

    created_by UUID NOT NULL
        REFERENCES auth.users(id) ON DELETE RESTRICT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at TIMESTAMPTZ,

    CONSTRAINT accounts_status_consistency CHECK (
        (status = 'active' AND closed_at IS NULL)
        OR
        (status = 'closed' AND closed_at IS NOT NULL)
    ),

    CONSTRAINT accounts_household_code_unique
        UNIQUE (household_id, code),

    CONSTRAINT accounts_household_id_unique
        UNIQUE (household_id, id)
);

CREATE INDEX accounts_household_status_idx
    ON public.accounts(household_id, status);


-- 2. CREDIT LIMIT HISTORY
-- Credit limits are independent of outstanding debt.
-- History is append-only.

CREATE TABLE public.credit_limit_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    household_id UUID NOT NULL,
    account_id UUID NOT NULL,

    limit_amount NUMERIC(18,2) NOT NULL
        CHECK (limit_amount >= 0),

    effective_on DATE NOT NULL,

    reason TEXT,

    recorded_by UUID NOT NULL
        REFERENCES auth.users(id) ON DELETE RESTRICT,

    recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT credit_limit_account_fk
        FOREIGN KEY (household_id, account_id)
        REFERENCES public.accounts(household_id, id)
        ON DELETE RESTRICT
);

CREATE INDEX credit_limit_lookup_idx
    ON public.credit_limit_history(
        household_id,
        account_id,
        effective_on DESC,
        recorded_at DESC,
        id DESC
    );


-- 3. TRANSACTIONS
-- A transaction is a financial event.
-- Amounts use exact decimal arithmetic.
-- Corrections must be new events.

CREATE TABLE public.transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    household_id UUID NOT NULL
        REFERENCES public.households(id) ON DELETE RESTRICT,

    kind TEXT NOT NULL
        CHECK (kind IN (
            'income',
            'expense',
            'transfer',
            'credit_charge',
            'credit_payment',
            'refund',
            'opening_balance',
            'adjustment',
            'reversal'
        )),

    amount NUMERIC(18,2) NOT NULL
        CHECK (amount > 0),

    interest_fees_amount NUMERIC(18,2) NOT NULL DEFAULT 0
        CHECK (interest_fees_amount >= 0),

    principal_amount NUMERIC(18,2) NOT NULL DEFAULT 0
        CHECK (principal_amount >= 0),

    occurred_on DATE NOT NULL,

    description TEXT,
    notes TEXT,

    refunded_transaction_id UUID,
    reverses_transaction_id UUID,

    idempotency_key TEXT
        CHECK (
            idempotency_key IS NULL
            OR char_length(idempotency_key)
                BETWEEN 1 AND 128
        ),

    created_by UUID NOT NULL
        REFERENCES auth.users(id) ON DELETE RESTRICT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT transactions_household_id_unique
        UNIQUE (household_id, id),

    CONSTRAINT transactions_idempotency_unique
        UNIQUE (household_id, idempotency_key),

    CONSTRAINT transactions_credit_payment_split CHECK (
        (
            kind = 'credit_payment'
            AND amount =
                interest_fees_amount + principal_amount
        )
        OR
        (
            kind <> 'credit_payment'
            AND interest_fees_amount = 0
            AND principal_amount = 0
        )
    ),

    CONSTRAINT transactions_refund_reference CHECK (
        (kind = 'refund') =
        (refunded_transaction_id IS NOT NULL)
    ),

    CONSTRAINT transactions_reversal_reference CHECK (
        (kind = 'reversal') =
        (reverses_transaction_id IS NOT NULL)
    ),

    CONSTRAINT transactions_no_self_refund CHECK (
        refunded_transaction_id IS NULL
        OR refunded_transaction_id <> id
    ),

    CONSTRAINT transactions_no_self_reversal CHECK (
        reverses_transaction_id IS NULL
        OR reverses_transaction_id <> id
    ),

    CONSTRAINT transactions_refund_fk
        FOREIGN KEY (
            household_id,
            refunded_transaction_id
        )
        REFERENCES public.transactions(household_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT transactions_reversal_fk
        FOREIGN KEY (
            household_id,
            reverses_transaction_id
        )
        REFERENCES public.transactions(household_id, id)
        ON DELETE RESTRICT
);

CREATE INDEX transactions_household_date_idx
    ON public.transactions(
        household_id,
        occurred_on DESC,
        created_at DESC
    );

CREATE INDEX transactions_refund_idx
    ON public.transactions(refunded_transaction_id)
    WHERE refunded_transaction_id IS NOT NULL;

CREATE UNIQUE INDEX transactions_one_reversal_idx
    ON public.transactions(reverses_transaction_id)
    WHERE reverses_transaction_id IS NOT NULL;


-- 4. ACCOUNT MOVEMENTS
--
-- Positive delta on bank/cash/savings: money increases.
-- Negative delta on bank/cash/savings: money decreases.
--
-- Positive delta on credit_card: debt increases.
-- Negative delta on credit_card: principal decreases.
--
-- Interest and fees never create a principal reduction.
-- An atomic posting function will enforce this invariant.

CREATE TABLE public.account_movements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    household_id UUID NOT NULL,
    transaction_id UUID NOT NULL,
    account_id UUID NOT NULL,

    amount_delta NUMERIC(18,2) NOT NULL
        CHECK (amount_delta <> 0),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT movements_transaction_fk
        FOREIGN KEY (household_id, transaction_id)
        REFERENCES public.transactions(household_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT movements_account_fk
        FOREIGN KEY (household_id, account_id)
        REFERENCES public.accounts(household_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT movements_one_entry_per_account
        UNIQUE (transaction_id, account_id)
);

CREATE INDEX movements_account_lookup_idx
    ON public.account_movements(
        household_id,
        account_id,
        transaction_id
    );


-- 5. VALIDATE CREDIT LIMIT ACCOUNT TYPE

CREATE FUNCTION private.validate_credit_limit_account()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.accounts a
        WHERE a.id = NEW.account_id
          AND a.household_id = NEW.household_id
          AND a.kind = 'credit_card'
    ) THEN
        RAISE EXCEPTION
            'Credit limit history requires a credit card account'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION
    private.validate_credit_limit_account() FROM PUBLIC;

CREATE TRIGGER validate_credit_limit_account
BEFORE INSERT ON public.credit_limit_history
FOR EACH ROW
EXECUTE FUNCTION private.validate_credit_limit_account();


-- 6. IMMUTABLE FINANCIAL HISTORY

CREATE FUNCTION private.block_financial_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    RAISE EXCEPTION
        'Financial history is append-only. Create a correction event.'
        USING ERRCODE = 'P0001';

    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION
    private.block_financial_mutation() FROM PUBLIC;

CREATE TRIGGER protect_transactions
BEFORE UPDATE OR DELETE ON public.transactions
FOR EACH ROW
EXECUTE FUNCTION private.block_financial_mutation();

CREATE TRIGGER protect_movements
BEFORE UPDATE OR DELETE ON public.account_movements
FOR EACH ROW
EXECUTE FUNCTION private.block_financial_mutation();

CREATE TRIGGER protect_credit_limits
BEFORE UPDATE OR DELETE ON public.credit_limit_history
FOR EACH ROW
EXECUTE FUNCTION private.block_financial_mutation();

CREATE TRIGGER protect_accounts_delete
BEFORE DELETE ON public.accounts
FOR EACH ROW
EXECUTE FUNCTION private.block_financial_mutation();


-- 7. UPDATED_AT

CREATE TRIGGER accounts_updated_at
BEFORE UPDATE ON public.accounts
FOR EACH ROW
EXECUTE FUNCTION private.touch_updated_at();


-- 8. FINANCIAL AUDIT TRIGGERS

CREATE TRIGGER audit_accounts
AFTER INSERT OR UPDATE OR DELETE
ON public.accounts
FOR EACH ROW
EXECUTE FUNCTION private.audit_household_change();

CREATE TRIGGER audit_credit_limits
AFTER INSERT OR UPDATE OR DELETE
ON public.credit_limit_history
FOR EACH ROW
EXECUTE FUNCTION private.audit_household_change();

CREATE TRIGGER audit_transactions
AFTER INSERT OR UPDATE OR DELETE
ON public.transactions
FOR EACH ROW
EXECUTE FUNCTION private.audit_household_change();

CREATE TRIGGER audit_account_movements
AFTER INSERT OR UPDATE OR DELETE
ON public.account_movements
FOR EACH ROW
EXECUTE FUNCTION private.audit_household_change();


-- 9. ROW LEVEL SECURITY

ALTER TABLE public.accounts
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.credit_limit_history
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.transactions
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.account_movements
    ENABLE ROW LEVEL SECURITY;


-- 10. EXPLICIT PRIVILEGES
-- No direct financial writes from browser clients.
-- Posting will be performed by controlled server functions.

REVOKE ALL ON
    public.accounts,
    public.credit_limit_history,
    public.transactions,
    public.account_movements
FROM anon, authenticated;

GRANT SELECT ON
    public.accounts,
    public.credit_limit_history,
    public.transactions,
    public.account_movements
TO authenticated;


-- 11. HOUSEHOLD READ POLICIES

CREATE POLICY accounts_select_member
ON public.accounts
FOR SELECT
TO authenticated
USING (
    private.is_household_member(household_id)
);

CREATE POLICY credit_limits_select_member
ON public.credit_limit_history
FOR SELECT
TO authenticated
USING (
    private.is_household_member(household_id)
);

CREATE POLICY transactions_select_member
ON public.transactions
FOR SELECT
TO authenticated
USING (
    private.is_household_member(household_id)
);

CREATE POLICY movements_select_member
ON public.account_movements
FOR SELECT
TO authenticated
USING (
    private.is_household_member(household_id)
);

-- No INSERT, UPDATE or DELETE policies.
-- Writes will be implemented through validated
-- atomic operations in a later migration.

-- No opening balances or financial transactions
-- are seeded in this migration.
