
import { Suspense } from "react";
import { connection } from "next/server";
import { redirect } from "next/navigation";
import { createClient } from "../../lib/supabase/server";

async function AuthenticatedHome() {
  // Render only when an actual request arrives.
  await connection();

  const supabase = await createClient();

  const { data, error } = await supabase.auth.getClaims();

  if (error || !data?.claims?.sub) {
    redirect("/login");
  }

  return (
    <main className="flex min-h-dvh items-center justify-center bg-zinc-950 px-4 text-zinc-100">
      <div className="w-full max-w-md rounded-2xl border border-zinc-800 bg-zinc-900 p-8 text-center">
        <h1 className="text-3xl font-bold">
          Family Budget
        </h1>

        <p className="mt-6 text-emerald-400">
          Успешно удостоверяване
        </p>

        <p className="mt-3 text-sm text-zinc-400">
          Сървърът потвърди твоята Auth сесия.
        </p>

        <p className="mt-8 text-xs text-zinc-500">
          Dashboard е в процес на разработка.
        </p>
      </div>
    </main>
  );
}

export default function HomePage() {
  return (
    <Suspense
      fallback={
        <main className="flex min-h-dvh items-center justify-center bg-zinc-950 text-zinc-400">
          Проверка на сесията...
        </main>
      }
    >
      <AuthenticatedHome />
    </Suspense>
  );
}
