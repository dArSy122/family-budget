import Link from "next/link";
import { Suspense } from "react";
import { connection } from "next/server";
import { redirect } from "next/navigation";

import { createClient } from "../../../lib/supabase/server";
import { CreateAccountPanel } from "./create-account-form";
import { RenameAccountControl } from "./rename-account-control";
import { AccountCloseControl } from "./account-close-control";

const accountKindLabels: Record<string, string> = {
  bank: "Разплащателна сметка",
  cash: "Пари в брой",
  savings: "Спестовна сметка",
  credit_card: "Кредитна карта",
};

async function AdminContent() {
  await connection();

  const supabase = await createClient();

  // Verify authentication.
  const { data: auth, error: authError } =
    await supabase.auth.getClaims();

  if (authError || !auth?.claims?.sub) {
    redirect("/login");
  }

  const userId = auth.claims.sub;

  // Only active Owners can access Administration.
  const { data: membership, error: membershipError } =
    await supabase
      .from("household_members")
      .select("household_id, role")
      .eq("user_id", userId)
      .eq("role", "owner")
      .eq("status", "active")
      .limit(1)
      .maybeSingle();

  if (membershipError) {
    throw new Error("Unable to verify Owner permissions.");
  }

  if (!membership) {
    redirect("/");
  }

  // Read accounts through household-scoped RLS.
  const { data: accounts, error: accountsError } =
    await supabase
      .from("accounts")
      .select(
        "id, code, name, kind, currency, status, closed_at"
      )
      .eq("household_id", membership.household_id)
      .order("name");

  if (accountsError) {
    throw new Error("Unable to load household accounts.");
  }

  // The UI uses one authoritative lifecycle status.
  const activeAccounts = accounts.filter(
    (account) => account.status === "active"
  );

  const closedAccounts = accounts.filter(
    (account) => account.status === "closed"
  );

  return (
    <main className="min-h-dvh bg-zinc-950 px-4 py-8 text-zinc-100">
      <div className="mx-auto max-w-5xl">
        <header className="mb-8">
          <Link
            href="/"
            className="text-sm text-emerald-400 hover:text-emerald-300"
          >
            ← Към Dashboard
          </Link>

          <p className="mt-6 text-xs uppercase tracking-widest text-zinc-500">
            Family Budget
          </p>

          <h1 className="mt-2 text-3xl font-bold">
            Администрация
          </h1>

          <p className="mt-3 text-sm text-zinc-400">
            Управление на финансовите сметки
            и настройките на домакинството.
          </p>
        </header>

        {/* Account statistics */}
        <section className="mb-8 grid grid-cols-2 gap-3 sm:grid-cols-3">
          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
            <p className="text-sm text-zinc-400">
              Общо сметки
            </p>
            <p className="mt-2 text-3xl font-semibold">
              {accounts.length}
            </p>
          </div>

          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
            <p className="text-sm text-zinc-400">
              Активни
            </p>
            <p className="mt-2 text-3xl font-semibold text-emerald-400">
              {activeAccounts.length}
            </p>
          </div>

          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
            <p className="text-sm text-zinc-400">
              Закрити
            </p>
            <p className="mt-2 text-3xl font-semibold">
              {closedAccounts.length}
            </p>
          </div>
        </section>

        {/* Create account */}
        <section className="mb-8">
          <CreateAccountPanel />
        </section>

        {/* Active accounts */}
        <section className="overflow-hidden rounded-2xl border border-zinc-800 bg-zinc-900">
          <div className="border-b border-zinc-800 px-5 py-5">
            <h2 className="text-xl font-semibold">
              Активни сметки ({activeAccounts.length})
            </h2>

            <p className="mt-1 text-sm text-zinc-400">
              Финансови сметки, достъпни за операции.
            </p>
          </div>

          {activeAccounts.length === 0 ? (
            <p className="p-6 text-sm text-zinc-400">
              Няма активни сметки.
            </p>
          ) : (
            <div className="divide-y divide-zinc-800">
              {activeAccounts.map((account) => (
                <div
                  key={account.id}
                  className="grid grid-cols-1 gap-4 p-5 md:grid-cols-[minmax(0,1fr)_14rem_9rem] md:items-center"
                >
                  <div className="min-w-0">
                    <h3 className="font-semibold">
                      {account.name}
                    </h3>

                    <p className="mt-1 text-sm text-zinc-400">
                      {accountKindLabels[account.kind] ??
                        account.kind}
                    </p>

                    <p className="mt-2 break-all font-mono text-xs text-zinc-500">
                      {account.code}
                    </p>
                  </div>

                  <div className="flex min-w-0 flex-wrap items-center gap-2">
                    <RenameAccountControl
                      accountId={account.id}
                      accountName={account.name}
                    />

                    <AccountCloseControl
                      accountId={account.id}
                      accountName={account.name}
                    />
                  </div>

                  <div className="flex items-center gap-3 md:justify-end">
                    <span className="text-xs text-zinc-400">
                      {account.currency}
                    </span>

                    <span className="rounded-full bg-emerald-950 px-3 py-1 text-xs text-emerald-400">
                      Активна
                    </span>
                  </div>
                </div>
              ))}
            </div>
          )}
        </section>

        {/* Closed accounts */}
        <section className="mt-6 overflow-hidden rounded-2xl border border-zinc-800 bg-zinc-900">
          <details>
            <summary className="cursor-pointer px-5 py-5 text-sm font-semibold text-zinc-200 hover:bg-zinc-800/50">
              Закрити сметки ({closedAccounts.length})
            </summary>

            {closedAccounts.length === 0 ? (
              <p className="border-t border-zinc-800 p-5 text-sm text-zinc-400">
                Няма закрити сметки.
              </p>
            ) : (
              <div className="divide-y divide-zinc-800 border-t border-zinc-800">
                {closedAccounts.map((account) => (
                  <div
                    key={account.id}
                    className="grid gap-3 p-5 sm:grid-cols-[minmax(0,1fr)_9rem] sm:items-center"
                  >
                    <div className="min-w-0">
                      <h3 className="font-semibold text-zinc-200">
                        {account.name}
                      </h3>

                      <p className="mt-1 text-sm text-zinc-400">
                        {accountKindLabels[account.kind] ??
                          account.kind}
                      </p>

                      <p className="mt-2 break-all font-mono text-xs text-zinc-500">
                        {account.code}
                      </p>

                      {account.closed_at && (
                        <p className="mt-2 text-xs text-zinc-500">
                          Закрита на:{" "}
                          {new Intl.DateTimeFormat("bg-BG", {
                            dateStyle: "medium",
                            timeZone: "Europe/Sofia",
                          }).format(new Date(account.closed_at))}
                        </p>
                      )}
                    </div>

                    <div className="sm:text-right">
                      <span className="rounded-full bg-zinc-800 px-3 py-1 text-xs text-zinc-300">
                        Закрита
                      </span>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </details>
        </section>

        <p className="mt-6 text-sm text-zinc-500">
          Закритите сметки остават в историята.
          Финансовите записи и одитът се запазват.
        </p>
      </div>
    </main>
  );
}

export default function AdminPage() {
  return (
    <Suspense
      fallback={
        <main className="min-h-dvh bg-zinc-950 px-4 py-8 text-zinc-100">
          <div className="mx-auto max-w-5xl">
            <p
              role="status"
              className="text-sm text-zinc-400"
            >
              Зареждане на администрацията...
            </p>
          </div>
        </main>
      }
    >
      <AdminContent />
    </Suspense>
  );
}