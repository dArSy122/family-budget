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

function RenameAccountDialog({
  accountId,
  accountName,
  onClose,
}: Props & {
  onClose: () => void;
}) {
  const [state, formAction, pending] = useActionState(
    manageAccountAction,
    initialState
  );

  const [name, setName] = useState(accountName);

  const completed = state.status === "success";
  const trimmedName = name.trim();

  return (
    <AccountDialog
      title="Редактиране на сметка"
      onClose={onClose}
      pending={pending}
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
          value="rename"
        />

        <div>
          <p className="text-sm text-zinc-400">
            Текущо име
          </p>

          <p className="mt-1 font-medium text-white">
            {accountName}
          </p>
        </div>

        <div>
          <label
            htmlFor={`rename-${accountId}`}
            className="mb-2 block text-sm font-medium text-zinc-200"
          >
            Ново име на сметката
          </label>

          <input
            id={`rename-${accountId}`}
            name="name"
            type="text"
            required
            maxLength={100}
            autoComplete="off"
            value={name}
            onChange={(event) =>
              setName(event.target.value)
            }
            disabled={pending || completed}
            className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-emerald-500 disabled:opacity-50"
          />
        </div>

        <p className="text-xs leading-5 text-zinc-400">
          Промяната засяга само името.
          Идентификаторът, балансът и финансовата
          история остават непроменени.
        </p>

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
                ? "text-sm text-emerald-400"
                : "text-sm text-red-400"
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
              disabled={
                pending ||
                trimmedName.length === 0 ||
                trimmedName === accountName
              }
              className="rounded-xl bg-emerald-600 px-5 py-3 text-sm font-semibold text-white hover:bg-emerald-500 disabled:cursor-not-allowed disabled:opacity-40"
            >
              {pending
                ? "Запазване..."
                : "Запази промените"}
            </button>
          )}
        </div>
      </form>
    </AccountDialog>
  );
}

export function RenameAccountControl({
  accountId,
  accountName,
}: Props) {
  const [isEditing, setIsEditing] = useState(false);

  return (
    <>
      <button
        type="button"
        onClick={() => setIsEditing(true)}
        className="rounded-lg border border-zinc-700 px-3 py-2 text-sm text-zinc-300 hover:border-emerald-700 hover:text-emerald-400"
      >
        Редактирай
      </button>

      {isEditing && (
        <RenameAccountDialog
          accountId={accountId}
          accountName={accountName}
          onClose={() => setIsEditing(false)}
        />
      )}
    </>
  );
}