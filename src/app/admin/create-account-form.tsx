"use client";

import { useActionState, useState } from "react";

import {
  createAccountAction,
  type CreateAccountState,
} from "./actions";

type AccountKind =
  | "bank"
  | "cash"
  | "savings"
  | "credit_card";

const initialState: CreateAccountState = {
  status: "idle",
  message: "",
  accountId: null,
};

function AccountCreationForm({
  requestId,
  onCancel,
  onAddAnother,
}: {
  requestId: string;
  onCancel: () => void;
  onAddAnother: () => void;
}) {
  const [state, formAction, pending] = useActionState(
    createAccountAction,
    initialState
  );

  const [name, setName] = useState("");
  const [kind, setKind] = useState<AccountKind>("bank");

  const completed = state.status === "success";

  return (
    <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5 sm:p-6">
      <div className="mb-5 flex items-start justify-between gap-4">
        <div>
          <h2 className="text-xl font-semibold text-zinc-100">
            Нова финансова сметка
          </h2>

          <p className="mt-2 text-sm text-zinc-400">
            Добавяне на банкова, касова, спестовна
            сметка или кредитна карта.
          </p>
        </div>

        <button
          type="button"
          onClick={onCancel}
          disabled={pending}
          className="rounded-lg px-3 py-2 text-sm text-zinc-400 hover:bg-zinc-800 hover:text-white disabled:opacity-50"
        >
          Затвори
        </button>
      </div>

      <form action={formAction} className="space-y-5">
        <input
          type="hidden"
          name="requestId"
          value={requestId}
        />

        <div>
          <label
            htmlFor="new-account-name"
            className="mb-2 block text-sm font-medium text-zinc-200"
          >
            Име на сметката
          </label>

          <input
            id="new-account-name"
            name="name"
            type="text"
            required
            maxLength={100}
            autoComplete="off"
            value={name}
            onChange={(event) => setName(event.target.value)}
            disabled={pending || completed}
            placeholder="Например: Банкова сметка"
            className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-zinc-100 outline-none placeholder:text-zinc-600 focus:border-emerald-500 disabled:opacity-60"
          />
        </div>

        <div>
          <label
            htmlFor="new-account-kind"
            className="mb-2 block text-sm font-medium text-zinc-200"
          >
            Тип сметка
          </label>

          <select
            id="new-account-kind"
            name="kind"
            value={kind}
            onChange={(event) =>
              setKind(event.target.value as AccountKind)
            }
            disabled={pending || completed}
            className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-zinc-100 outline-none focus:border-emerald-500 disabled:opacity-60"
          >
            <option value="bank">
              Разплащателна сметка
            </option>

            <option value="cash">
              Пари в брой
            </option>

            <option value="savings">
              Спестовна сметка
            </option>

            <option value="credit_card">
              Кредитна карта
            </option>
          </select>
        </div>

        <p className="text-xs leading-5 text-zinc-500">
          Валутата е EUR. Създаването на сметка
          не въвежда начален баланс или дълг.
        </p>

        {state.status !== "idle" && (
          <div
            role={
              state.status === "error"
                ? "alert"
                : "status"
            }
            aria-live="polite"
            className={
              state.status === "success"
                ? "rounded-xl border border-emerald-900 bg-emerald-950/40 p-4 text-sm text-emerald-300"
                : "rounded-xl border border-red-900 bg-red-950/40 p-4 text-sm text-red-300"
            }
          >
            <p>{state.message}</p>

            {completed && state.accountId && (
              <p className="mt-2 break-all font-mono text-xs">
                ID: {state.accountId}
              </p>
            )}
          </div>
        )}

        {completed ? (
          <button
            type="button"
            onClick={onAddAnother}
            className="w-full rounded-xl bg-emerald-600 px-5 py-3 font-semibold text-white hover:bg-emerald-500"
          >
            Добави друга сметка
          </button>
        ) : (
          <button
            type="submit"
            disabled={pending || !name.trim()}
            className="w-full rounded-xl bg-emerald-600 px-5 py-3 font-semibold text-white hover:bg-emerald-500 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {pending
              ? "Създаване..."
              : "Създай сметка"}
          </button>
        )}
      </form>
    </div>
  );
}

export function CreateAccountPanel() {
  const [requestId, setRequestId] = useState<
    string | null
  >(null);

  function startNewAccount() {
    setRequestId(crypto.randomUUID());
  }

  if (requestId === null) {
    return (
      <button
        type="button"
        onClick={startNewAccount}
        className="w-full rounded-2xl border border-emerald-800 bg-emerald-950/30 px-5 py-4 text-left font-semibold text-emerald-300 transition hover:border-emerald-600 hover:bg-emerald-950/50"
      >
        + Добави финансова сметка
      </button>
    );
  }

  return (
    <AccountCreationForm
      key={requestId}
      requestId={requestId}
      onCancel={() => setRequestId(null)}
      onAddAnother={startNewAccount}
    />
  );
}