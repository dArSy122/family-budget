"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "../../../../lib/supabase/server";

export type FinancialSetupActionState = {
  status: "idle" | "success" | "error";
  message: string;
};

type SetupOperation = "opening" | "credit_limit";

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const amountPattern =
  /^(?:0|[1-9][0-9]{0,15})(?:[.,][0-9]{1,2})?$/;

function failure(message: string): FinancialSetupActionState {
  return {
    status: "error",
    message,
  };
}

function parseEuroAmount(value: FormDataEntryValue | null) {
  if (typeof value !== "string") {
    return null;
  }

  const input = value.trim();

  // Empty is unknown, not zero.
  if (!amountPattern.test(input)) {
    return null;
  }

  const normalized = input.replace(",", ".");
  const [integer, fraction = ""] = normalized.split(".");

  // Canonical decimal representation.
  // No floating-point financial arithmetic.
  return `${integer}.${fraction.padEnd(2, "0")}`;
}

export async function confirmFinancialSetupAction(
  _previousState: FinancialSetupActionState,
  formData: FormData
): Promise<FinancialSetupActionState> {
  // Financial writes remain disabled until staging validation.
  // The environment flag is checked on the server.
  if (process.env.FINANCIAL_SETUP_WRITES_ENABLED !== "true") {
    return failure(
      "Финансовите записи още не са активирани. " +
        "Първо трябва да приключат Staging тестовете."
    );
  }

  const supabase = await createClient();

  // 1. Authenticate every financial mutation.
  const { data: auth, error: authError } =
    await supabase.auth.getClaims();

  if (authError || !auth?.claims?.sub) {
    redirect("/login");
  }

  // 2. Resolve the household from Owner membership.
  // Never accept a household ID from the browser.
  const { data: membership, error: membershipError } =
    await supabase
      .from("household_members")
      .select("household_id")
      .eq("user_id", auth.claims.sub)
      .eq("role", "owner")
      .eq("status", "active")
      .limit(1)
      .maybeSingle();

  if (membershipError || !membership) {
    return failure("Нямаш активно Owner членство.");
  }

  const householdId = membership.household_id;

  // 3. Validate submitted operation and account ID.
  const rawOperation = formData.get("operation");
  const rawAccountId = formData.get("accountId");

  if (
    rawOperation !== "opening" &&
    rawOperation !== "credit_limit"
  ) {
    return failure("Невалидна финансова операция.");
  }

  const operation: SetupOperation = rawOperation;

  if (
    typeof rawAccountId !== "string" ||
    !uuidPattern.test(rawAccountId)
  ) {
    return failure("Невалидна финансова сметка.");
  }

  // 4. Validate the exact decimal amount.
  const amount = parseEuroAmount(formData.get("amount"));

  if (amount === null) {
    return failure(
      "Въведи сума в EUR с до два знака след " +
      "десетичния разделител. Например 125,50."
    );
  }

  // 5. Read current account state from the database.
  const { data: account, error: accountError } =
    await supabase
      .from("accounts")
      .select("id, kind, status")
      .eq("household_id", householdId)
      .eq("id", rawAccountId)
      .maybeSingle();

  if (accountError || !account) {
    return failure(
      "Сметката не е открита в твоето домакинство."
    );
  }

  if (account.status !== "active") {
    return failure("Сметката не е активна.");
  }

  if (
    operation === "credit_limit" &&
    account.kind !== "credit_card"
  ) {
    return failure(
      "Кредитен лимит се въвежда само за кредитна карта."
    );
  }

  // 6. Use database RPCs for all financial writes.
  // PostgreSQL performs the final Owner authorization,
  // locking, idempotency and audit operations.
  if (operation === "opening") {
    const { error } = await supabase.rpc(
      "confirm_account_opening",
      {
        p_household_id: householdId,
        p_account_id: account.id,
        p_amount: amount,
        p_notes: null,
      }
    );

    if (error) {
      if (error.code === "42501") {
        return failure("Нямаш разрешение за тази операция.");
      }

      if (error.code === "23505") {
        if (
          error.message.includes(
            "Account already has financial movements"
          )
        ) {
          return failure(
            "Сметката вече има финансови движения. " +
            "Начално салдо не може да бъде добавено."
          );
        }

        if (
          error.message.includes(
            "Opening already confirmed with different data"
          )
        ) {
          return failure(
            "Началното салдо вече е потвърдено. " +
            "Различна стойност изисква отделна корекция."
          );
        }

        return failure(
          "Конфликт със съществуващи финансови данни. " +
          "Началното салдо не е записано."
        );
      }

      if (error.code === "23514") {
        return failure(
          "Началното салдо не премина финансовите проверки. " +
          "При кредитна карта провери главницата и лимита."
        );
      }

      return failure(
        "Неуспешно записване на началното салдо."
      );
    }

    revalidatePath("/setup/financial");

    return {
      status: "success",
      message: "Началното салдо е потвърдено.",
    };
  }

  const { error } = await supabase.rpc(
    "confirm_initial_credit_limit",
    {
      p_household_id: householdId,
      p_account_id: account.id,
      p_limit_amount: amount,
    }
  );

  if (error) {
    if (error.code === "42501") {
      return failure("Нямаш разрешение за тази операция.");
    }

    if (error.code === "23505") {
      return failure(
        "Началният кредитен лимит вече е потвърден " +
        "с различна стойност."
      );
    }

    if (error.code === "23514") {
      return failure(
        "Лимитът противоречи на кредитната история " +
        "или на текущото задължение."
      );
    }

    return failure(
      "Неуспешно записване на кредитния лимит."
    );
  }

  revalidatePath("/setup/financial");

  return {
    status: "success",
    message: "Началният кредитен лимит е потвърден.",
  };
}