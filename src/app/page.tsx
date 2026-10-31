import { Suspense } from "react";
import { connection } from "next/server";
import { redirect } from "next/navigation";
import { createClient } from "../../lib/supabase/server";

async function AuthenticatedHome() {
  await connection();

  const supabase = await createClient();

  // Step 1: Verify authenticated session.
  const { data: auth, error: authError } =
    await supabase.auth.getClaims();

  if (authError || !auth?.claims?.sub) {
    redirect("/login");
  }

  const userId = auth.claims.sub;

  // Step 2: Check active household membership.
  const { data: membership, error: membershipError } =
    await supabase
      .from("household_members")
      .select("household_id")
      .eq("user_id", userId)
      .eq("status", "active")
      .limit(1)
      .maybeSingle();

  if (membershipError) {
    throw new Error(
      "Unable to verify household membership."
    );
  }

  // Step 3: First-run setup for new users.
  if (!membership) {
    redirect("/setup");
  }

  // Step 4: Authenticated user with an active household.
  return (
    <main className="flex min-h-dvh items-center justify-center bg-zinc-950 px-4 text-zinc-100">
      <div className="w-full max-w-md rounded-2xl border border-zinc-800 bg-zinc-900 p-8 text-center">
        <p className="text-sm font-medium text-emerald-400">
          Family Budget
        </p>

        <h1 className="mt-4 text-3xl font-bold">
          Dashboard
        </h1>

        <p className="mt-6 text-emerald-400">
          Успешно удостоверяване
        </p>

        <p className="mt-3 text-sm text-zinc-400">
          Профилът има активно домакинство.
        </p>

        <p className="mt-8 text-xs text-zinc-500">
          Финансовият Dashboard предстои.
        </p>
      </div>
    </main>
  );
}

export default function HomePage() {
  return (
    <Suspense
      fallback={
        <main className="flex min-h-dvh items-center justify-center bg-zinc-950 px-4 text-zinc-400">
          Проверка на профила и домакинството...
        </main>
      }
    >
      <AuthenticatedHome />
    </Suspense>
  );
}