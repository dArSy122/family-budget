import { Suspense } from "react";
import { connection } from "next/server";
import { redirect } from "next/navigation";
import { createClient } from "../../../lib/supabase/server";


async function createHousehold(formData: FormData) {
  "use server";

  const value = formData.get("household_name");

  if (typeof value !== "string") {
    redirect("/setup?error=invalid_name");
  }

  const name = value.trim();

  if (name.length === 0 || name.length > 100) {
    redirect("/setup?error=invalid_name");
  }

  const supabase = await createClient();

  const { data: auth, error: authError } =
    await supabase.auth.getClaims();

  if (authError || !auth?.claims?.sub) {
    redirect("/login");
  }

  const { data: householdId, error } = await supabase.rpc(
    "setup_household",
    {
      p_name: name,
    }
  );

  if (error || !householdId) {
    redirect("/setup?error=setup_failed");
  }

  redirect("/");
}

type SetupPageProps = {
  searchParams: Promise<{
    error?: string;
  }>;
};

async function SetupContent({
  searchParams,
}: SetupPageProps) {
  await connection();

  const supabase = await createClient();

  const { data: auth, error: authError } =
    await supabase.auth.getClaims();

  if (authError || !auth?.claims?.sub) {
    redirect("/login");
  }

  const userId = auth.claims.sub;

  const { data: membership, error: membershipError } =
    await supabase
      .from("household_members")
      .select("household_id")
      .eq("user_id", userId)
      .eq("status", "active")
      .limit(1)
      .maybeSingle();

  if (membershipError) {
    throw new Error("Unable to verify household membership.");
  }

  if (membership) {
    redirect("/");
  }

  const { error } = await searchParams;

  const errorMessage =
    error === "invalid_name"
      ? "Въведи име на домакинството до 100 символа."
      : error === "setup_failed"
        ? "Домакинството не е създадено. Провери състоянието на профила."
        : null;

  return (
    <main className="flex min-h-dvh items-center justify-center bg-zinc-950 px-4 py-10 text-zinc-100">
      <div className="w-full max-w-lg rounded-2xl border border-zinc-800 bg-zinc-900 p-6 shadow-xl sm:p-8">
        <div className="mb-8">
          <p className="text-sm font-medium text-emerald-400">
            Family Budget
          </p>

          <p className="mt-2 text-xs uppercase tracking-widest text-zinc-500">
            Първоначална настройка
          </p>

          <h1 className="mt-4 text-2xl font-bold">
            Създай домакинство
          </h1>

          <p className="mt-3 text-sm leading-6 text-zinc-400">
            Това е първата стъпка от настройката на
            семейния бюджет.
          </p>
        </div>

        {errorMessage && (
          <div
            role="alert"
            className="mb-6 rounded-xl border border-red-900 bg-red-950/40 p-4 text-sm text-red-300"
          >
            {errorMessage}
          </div>
        )}

        <form action={createHousehold} className="space-y-6">
          <div>
            <label
              htmlFor="household_name"
              className="mb-2 block text-sm font-medium text-zinc-200"
            >
              Име на домакинството
            </label>

            <input
              id="household_name"
              name="household_name"
              type="text"
              required
              minLength={1}
              maxLength={100}
              defaultValue="Family Budget"
              autoComplete="off"
              className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-zinc-100 outline-none focus:border-emerald-500 focus:ring-2 focus:ring-emerald-500/20"
            />

            <p className="mt-2 text-xs text-zinc-500">
              Името служи за идентифициране на
              семейния бюджет.
            </p>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
              <p className="text-xs text-zinc-500">Валута</p>
              <p className="mt-1 font-medium">EUR (€)</p>
            </div>

            <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
              <p className="text-xs text-zinc-500">
                Часова зона
              </p>
              <p className="mt-1 font-medium">Europe/Sofia</p>
            </div>
          </div>

          <button
            type="submit"
            className="w-full rounded-xl bg-emerald-500 px-5 py-3 font-semibold text-zinc-950 transition-colors hover:bg-emerald-400 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-emerald-400"
          >
            Създай домакинство
          </button>
        </form>

        <p className="mt-6 text-center text-xs leading-5 text-zinc-500">
          Финансовите сметки и началните баланси
          ще конфигурираме в следващите стъпки.
        </p>
      </div>
    </main>
  );
}

export default function SetupPage({
  searchParams,
}: SetupPageProps) {
  return (
    <Suspense
      fallback={
        <main className="flex min-h-dvh items-center justify-center bg-zinc-950 px-4 py-10 text-zinc-100">
          <div className="w-full max-w-lg rounded-2xl border border-zinc-800 bg-zinc-900 p-6">
            <p
              role="status"
              className="text-sm text-zinc-400"
            >
              Зареждане на първоначалната настройка...
            </p>
          </div>
        </main>
      }
    >
      <SetupContent searchParams={searchParams} />
    </Suspense>
  );
}