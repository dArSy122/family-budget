-- Prevent modification or deletion of existing audit records.
-- Audit history must remain append-only.

CREATE TRIGGER protect_audit_log
BEFORE UPDATE OR DELETE
ON public.audit_log
FOR EACH ROW
EXECUTE FUNCTION private.block_financial_mutation();

COMMENT ON TRIGGER protect_audit_log ON public.audit_log IS
'Prevents UPDATE and DELETE of audit history. Corrections must be recorded as new events.';