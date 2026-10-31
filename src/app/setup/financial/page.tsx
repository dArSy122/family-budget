import Link from "next/link";
import { Suspense } from "react";
import { connection } from "next/server";
import { redirect } from "next/navigation";
import { createClient } from "../../../../lib/supabase/server";
import { FinancialSetupForm } from "./financial-setup-form";

const currencyFormatter = new Intl.NumberFormat("bg-BG", {
  style: "currency",
  currency: "EUR",
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

const kindLabels: Record<string, string> = {
  bank: "Разплащателна сметка",
  cash: "Пари в брой",
  savings: "Спестовна сметка",
  credit_card: "Кредитна карта",
};

function formatAmount(value: number | string): string {
  return currencyFormatter.format(Number(value));
}

async function FinancialSetupContent() {
  await connection();

  const supabase = await createClient();

  // 1. Authentication.
  const { data: auth, error: authError } =
    await supabase.auth.getClaims();

  if (authError || !auth?.claims?.sub) {
    redirect("/login");
  }

  // 2. Owner membership.
  const { data: membership, error: membershipError } =
    await supabase
      .from("household_members")
      .select("household_id")
      .eq("user_id", auth.claims.sub)
      .eq("role", "owner")
      .eq("status", "active")
      .limit(1)
      .maybeSingle();

  if (membershipError) {
    throw new Error("Unable to verify Owner membership.");
  }

  if (!membership) {
    redirect("/");
  }

  const householdId = membership.household_id;

  // 3. Read financial setup data through RLS.
  const [
    accountsResult,
    confirmationsResult,
    limitsResult,
  ] = await Promise.all([
    supabase
      .from("accounts")
      .select(
        "id, code, name, kind, currency, status, ledger_entries:account_movements(count)"
      )
      .eq("household_id", householdId)
      .eq("status", "active")
      .order("name"),

    supabase
      .from("account_opening_confirmations")
      .select("account_id, opening_amount, confirmed_at")
      .eq("household_id", householdId),

    supabase
      .from("credit_limit_history")
      .select("account_id, limit_amount, effective_on")
      .eq("household_id", householdId)
      .lte("effective_on", "2026-11-01")
      .order("effective_on", { ascending: false })
      .order("recorded_at", { ascending: false })
      .order("id", { ascending: false }),
  ]);

  if (
    accountsResult.error ||
    confirmationsResult.error ||
    limitsResult.error
  ) {
    throw new Error(
      "Unable to load initial financial setup."
    );
  }

  const accounts = accountsResult.data ?? [];
  const confirmations = confirmationsResult.data ?? [];
  const limits = limitsResult.data ?? [];

  const confirmationByAccount = new Map(
    confirmations.map((confirmation) => [
      confirmation.account_id,
      confirmation,
    ])
  );

  // The first record per account is the effective
  // limit on the budget start date.
  const limitByAccount = new Map<
    string,
    number | string
  >();

  for (const limit of limits) {
    if (!limitByAccount.has(limit.account_id)) {
      limitByAccount.set(
        limit.account_id,
        limit.limit_amount
      );
    }
  }

  const legacyOpeningAccounts = accounts.filter(
    (account) =>
      !confirmationByAccount.has(account.id) &&
      (account.ledger_entries?.[0]?.count ?? 0) > 0
  ).length;

  const eligibleOpeningAccounts =
    accounts.length - legacyOpeningAccounts;

  const confirmedAccounts = accounts.filter(
    (account) => confirmationByAccount.has(account.id)
  ).length;

  const creditCards = accounts.filter(
    (account) => account.kind === "credit_card"
  );

  const confirmedCreditLimits = creditCards.filter(
    (account) => limitByAccount.has(account.id)
  ).length;

    const writesEnabled =
    process.env.FINANCIAL_SETUP_WRITES_ENABLED === "true";

  return (
    <main className="min-h-dvh bg-zinc-950 px-4 py-8 text-zinc-100">
      <div className="mx-auto max-w-4xl">
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
            Начална финансова настройка
          </h1>

          <p className="mt-3 text-sm leading-6 text-zinc-400">
            Начално състояние към 01.11.2026.
            Наличностите, дълговете и кредитните
            лимити се потвърждават отделно.
          </p>
        </header>

        <section className="mb-8 grid grid-cols-2 gap-3">
          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
            <p className="text-sm text-zinc-400">
              Потвърдени салда
            </p>

            <p className="mt-2 text-2xl font-semibold">
              {confirmedAccounts} / {eligibleOpeningAccounts}
            </p>
            {legacyOpeningAccounts > 0 && (
              <p className="mt-2 text-xs text-zinc-500">
                Сметки с финансова история извън прогреса: {legacyOpeningAccounts}
              </p>
            )}
          </div>

          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
            <p className="text-sm text-zinc-400">
              Кредитни лимити
            </p>

            <p className="mt-2 text-2xl font-semibold">
              {confirmedCreditLimits} / {creditCards.length}
            </p>
          </div>
        </section>

        <section className="overflow-hidden rounded-2xl border border-zinc-800 bg-zinc-900">
          <div className="border-b border-zinc-800 p-5">
            <h2 className="text-xl font-semibold">
              Активни финансови сметки
            </h2>

            <p className="mt-2 text-sm text-zinc-400">
              Показват се само сметките на твоето
              домакинство. Закритите сметки не
              участват в началната настройка.
            </p>
          </div>

          {accounts.length === 0 ? (
            <p className="p-5 text-sm text-zinc-400">
              Няма активни сметки. Провери
              конфигурацията в администрацията.
            </p>
          ) : (
            <div className="divide-y divide-zinc-800">
              {accounts.map((account) => {
                const confirmation =
                  confirmationByAccount.get(account.id);

                const isCreditCard =
                  account.kind === "credit_card";

                const creditLimit =
                  limitByAccount.get(account.id);

                const hasLedgerMovements =
                  (account.ledger_entries?.[0]?.count ?? 0) > 0;

                return (
                  <article
                    key={account.id}
                    className="p-5"
                  >
                    <div className="flex flex-wrap items-start justify-between gap-3">
                      <div>
                        <h3 className="font-semibold">
                          {account.name}
                        </h3>

                        <p className="mt-1 text-sm text-zinc-400">
                          {kindLabels[account.kind] ??
                            account.kind}
                        </p>
                      </div>

                      <span
                        className={
                          confirmation
                            ? "rounded-full bg-emerald-950 px-3 py-1 text-xs text-emerald-400"
                            : hasLedgerMovements
                              ? "rounded-full bg-amber-950/60 px-3 py-1 text-xs text-amber-300"
                              : "rounded-full bg-zinc-800 px-3 py-1 text-xs text-zinc-300"
                        }
                      >
                        {confirmation
                          ? "Потвърдено"
                          : hasLedgerMovements
                            ? "Има финансова история"
                            : "Очаква потвърждение"}
                      </span>
                    </div>

                    <div className="mt-5 grid gap-3 sm:grid-cols-2">
                      <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                        <p className="text-xs text-zinc-400">
                          {isCreditCard
                            ? "Начална главница"
                            : "Начална наличност"}
                        </p>

                        <p className="mt-2 text-lg font-semibold">
                          {confirmation
                            ? formatAmount(confirmation.opening_amount)
                            : hasLedgerMovements
                              ? "Няма потвърдено начално салдо"
                              : "Очаква сума"}
                        </p>
                      </div>

                      {isCreditCard && (
                        <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                          <p className="text-xs text-zinc-400">
                            Начален кредитен лимит
                          </p>

                          <p className="mt-2 text-lg font-semibold">
                            {creditLimit !== undefined
                              ? formatAmount(creditLimit)
                              : "Очаква лимит"}
                          </p>
                        </div>
                      )}
                    </div>

                    {!confirmation && !hasLedgerMovements && (
                      <FinancialSetupForm
                        accountId={account.id}
                        operation="opening"
                        writesEnabled={writesEnabled}
                      />
                    )}

                    {!confirmation && hasLedgerMovements && (
                      <p className="mt-4 rounded-xl border border-amber-900/50 bg-amber-950/20 p-4 text-sm leading-6 text-amber-200">
                        Тази сметка вече има финансови движения.
                        Начално салдо не може да бъде добавено
                        със задна дата чрез първоначалната настройка.
                        Съществуващата финансова история се запазва.
                      </p>
                    )}

                    {isCreditCard &&
                      creditLimit === undefined && (
                        <FinancialSetupForm
                          accountId={account.id}
                          operation="credit_limit"
                          writesEnabled={writesEnabled}
                        />
                      )}

                    <p className="mt-4 font-mono text-xs text-zinc-500">
                      {account.code}
                    </p>
                  </article>
                );
              })}
            </div>
          )}
        </section>

        <div className="mt-6 rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
          <h2 className="font-semibold">
            Следваща стъпка
          </h2>

          <p className="mt-2 text-sm leading-6 text-zinc-400">
            Ще добавим защитените форми за
            въвеждане на начални салда и кредитни
            лимити. Празното поле няма да се
            третира като нула.
          </p>

          <Link
            href="/admin"
            className="mt-4 inline-block text-sm text-emerald-400 hover:text-emerald-300"
          >
            Управление на сметки
          </Link>
        </div>
      </div>
    </main>
  );
}

export default function FinancialSetupPage() {
  return (
    <Suspense
      fallback={
        <main className="flex min-h-dvh items-center justify-center bg-zinc-950 px-4 text-zinc-400">
          <p role="status">
            Зареждане на финансовата настройка...
          </p>
        </main>
      }
    >
      <FinancialSetupContent />
    </Suspense>
  );
}