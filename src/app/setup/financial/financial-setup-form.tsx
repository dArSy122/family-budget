"use client";

import { useActionState } from "react";

import {
  confirmFinancialSetupAction,
  type FinancialSetupActionState,
} from "./actions";

type FinancialSetupFormProps = {
  accountId: string;
  operation: "opening" | "credit_limit";
  writesEnabled: boolean;
};

const initialState: FinancialSetupActionState = {
  status: "idle",
  message: "",
};

export function FinancialSetupForm({
  accountId,
  operation,
  writesEnabled,
}: FinancialSetupFormProps) {
  const [state, formAction, isPending] = useActionState(
    confirmFinancialSetupAction,
    initialState
  );

  const isOpening = operation === "opening";

  const inputId = `amount-${operation}-${accountId}`;

  const label = isOpening
    ? "Въведи начална сума"
    : "Въведи кредитен лимит";

  const buttonLabel = isOpening
    ? "Потвърди начално салдо"
    : "Потвърди кредитен лимит";

  return (
    <form
      action={formAction}
      className="mt-4 rounded-xl border border-zinc-700 bg-zinc-950 p-4"
    >
      <input
        type="hidden"
        name="accountId"
        value={accountId}
      />

      <input
        type="hidden"
        name="operation"
        value={operation}
      />

      <label
        htmlFor={inputId}
        className="block text-sm font-medium text-zinc-200"
      >
        {label}
      </label>

      <div className="mt-3 flex flex-col gap-3 sm:flex-row">
        <div className="relative min-w-0 flex-1">
          <input
            id={inputId}
            name="amount"
            type="text"
            inputMode="decimal"
            autoComplete="off"
            required
            maxLength={19}
            pattern="(?:0|[1-9][0-9]{0,15})(?:[.,][0-9]{1,2})?"
            placeholder="0,00"
            aria-label={`${label} в евро`}
            className="w-full rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-3 pr-12 text-zinc-100 outline-none focus:border-emerald-500 focus:ring-2 focus:ring-emerald-500/20"
          />

          <span
            aria-hidden="true"
            className="pointer-events-none absolute inset-y-0 right-4 flex items-center text-sm text-zinc-400"
          >
            EUR
          </span>
        </div>

        <button
          type="submit"
          disabled={!writesEnabled || isPending}
          className="rounded-xl bg-emerald-500 px-5 py-3 text-sm font-semibold text-zinc-950 transition-colors hover:bg-emerald-400 disabled:cursor-not-allowed disabled:bg-zinc-700 disabled:text-zinc-400"
        >
          {isPending ? "Записване..." : buttonLabel}
        </button>
      </div>

      <p className="mt-3 text-xs leading-5 text-zinc-500">
        {isOpening
          ? "Въведи 0 само ако потвърждаваш нулево салдо. При кредитна карта посочи само главницата."
          : "Кредитният лимит е отделен от използваната главница и начислените лихви."}
      </p>

      {!writesEnabled && (
        <p className="mt-3 text-xs text-amber-300">
          Записването е заключено до приключване на
          Staging тестовете.
        </p>
      )}

      {state.status !== "idle" && (
        <p
          role={state.status === "error" ? "alert" : "status"}
          aria-live="polite"
          className={
            state.status === "success"
              ? "mt-3 text-sm text-emerald-400"
              : "mt-3 text-sm text-red-400"
          }
        >
          {state.message}
        </p>
      )}
    </form>
  );
}