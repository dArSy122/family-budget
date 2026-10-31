"use client";

import { useActionState, useState } from "react";

import { AccountDialog } from "./account-dialog";

import {
  manageAccountAction,
  type AccountManagementState,
} from "./actions";

type Props = {
  accountId: string;
  accountName: string;
};

const initialState: AccountManagementState = {
  status: "idle",
  message: "",
  accountId: null,
};

function CloseAccountDialog({
  accountId,
  accountName,
  onClose,
}: Props & {
  onClose: () => void;
}) {
  const [confirmation, setConfirmation] = useState("");

  const [state, formAction, pending] = useActionState(
    manageAccountAction,
    initialState
  );

  const completed = state.status === "success";
  const nameMatches = confirmation === accountName;

  return (
    <AccountDialog
      title="Закриване на сметка"
      onClose={onClose}
      pending={pending}
      danger
    >
      <form action={formAction} className="space-y-5">
        <input
          type="hidden"
          name="accountId"
          value={accountId}
        />

        <input
          type="hidden"
          name="operation"
          value="close"
        />

        <div className="rounded-xl border border-red-900/50 bg-zinc-950 p-4">
          <p className="text-xs text-zinc-400">
            Финансова сметка
          </p>

          <p className="mt-2 break-words text-lg font-semibold text-white">
            {accountName}
          </p>
        </div>

        <div className="space-y-3 text-sm leading-6 text-zinc-300">
          <p>
            Закриването блокира новите финансови
            операции по тази сметка.
          </p>

          <p>
            Финансовата история и Audit Log
            остават запазени.
          </p>

          <p className="text-amber-400">
            PostgreSQL ще откаже закриване
            при ненулев баланс или бъдещи
            осчетоводени движения.
          </p>
        </div>

        <div className="space-y-3">
          <label
            htmlFor={`close-confirm-${accountId}`}
            className="block text-sm font-medium text-zinc-200"
          >
            Въведи точно името на сметката:
          </label>

          <p className="break-words rounded-lg bg-zinc-950 px-4 py-3 font-medium text-white">
            {accountName}
          </p>

          <input
            id={`close-confirm-${accountId}`}
            name="confirmationName"
            type="text"
            value={confirmation}
            onChange={(event) =>
              setConfirmation(event.target.value)
            }
            autoComplete="off"
            spellCheck={false}
            required
            disabled={pending || completed}
            placeholder="Потвърди името"
            className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-red-500 disabled:opacity-50"
          />
        </div>

        {state.status !== "idle" && (
          <p
            role={
              state.status === "error"
                ? "alert"
                : "status"
            }
            aria-live="polite"
            className={
              completed
                ? "rounded-xl border border-emerald-900 bg-emerald-950/30 p-3 text-sm text-emerald-300"
                : "rounded-xl border border-red-900 bg-red-950/30 p-3 text-sm text-red-300"
            }
          >
            {state.message}
          </p>
        )}

        <div className="flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
          <button
            type="button"
            onClick={onClose}
            disabled={pending}
            className="rounded-xl border border-zinc-700 px-5 py-3 text-sm text-zinc-300 hover:bg-zinc-800 disabled:opacity-50"
          >
            {completed ? "Готово" : "Отказ"}
          </button>

          {!completed && (
            <button
              type="submit"
              disabled={pending || !nameMatches}
              className="rounded-xl bg-red-700 px-5 py-3 text-sm font-semibold text-white hover:bg-red-600 disabled:cursor-not-allowed disabled:opacity-40"
            >
              {pending
                ? "Закриване..."
                : "Потвърди закриването"}
            </button>
          )}
        </div>
      </form>
    </AccountDialog>
  );
}

export function AccountCloseControl({
  accountId,
  accountName,
}: Props) {
  const [isOpen, setIsOpen] = useState(false);

  return (
    <>
      <button
        type="button"
        onClick={() => setIsOpen(true)}
        className="rounded-lg border border-red-900 px-3 py-2 text-sm text-red-400 hover:border-red-600 hover:bg-red-950/30"
      >
        Закрий
      </button>

      {isOpen && (
        <CloseAccountDialog
          accountId={accountId}
          accountName={accountName}
          onClose={() => setIsOpen(false)}
        />
      )}
    </>
  );
}