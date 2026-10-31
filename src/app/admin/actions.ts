"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "../../../lib/supabase/server";

export type CreateAccountState = {
  status: "idle" | "success" | "error";
  message: string;
  accountId: string | null;
};

const allowedKinds = [
  "bank",
  "cash",
  "savings",
  "credit_card",
];

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function failure(message: string): CreateAccountState {
  return {
    status: "error",
    message,
    accountId: null,
  };
}

export async function createAccountAction(
  _previousState: CreateAccountState,
  formData: FormData
): Promise<CreateAccountState> {
  const supabase = await createClient();

  // Authentication must be checked inside the action.
  const { data: auth, error: authError } =
    await supabase.auth.getClaims();

  if (authError || !auth?.claims?.sub) {
    redirect("/login");
  }

  const userId = auth.claims.sub;

  // Resolve household from verified membership.
  // Never trust a household ID supplied by the browser.
  const { data: membership, error: membershipError } =
    await supabase
      .from("household_members")
      .select("household_id")
      .eq("user_id", userId)
      .eq("role", "owner")
      .eq("status", "active")
      .limit(1)
      .maybeSingle();

  if (membershipError) {
    return failure(
      "Неуспешна проверка на административните права."
    );
  }

  if (!membership) {
    return failure(
      "Нямаш активни Owner права."
    );
  }

  const rawName = formData.get("name");
  const rawKind = formData.get("kind");
  const rawRequestId = formData.get("requestId");

  if (typeof rawName !== "string") {
    return failure("Въведи име на сметката.");
  }

  const name = rawName.trim();

  if (
    name.length === 0 ||
    Array.from(name).length > 100
  ) {
    return failure(
      "Името трябва да съдържа от 1 до 100 символа."
    );
  }

  if (
    typeof rawKind !== "string" ||
    !allowedKinds.includes(rawKind)
  ) {
    return failure("Невалиден тип сметка.");
  }

  if (
    typeof rawRequestId !== "string" ||
    !uuidPattern.test(rawRequestId)
  ) {
    return failure("Невалиден идентификатор на заявката.");
  }

  // Database RPC performs the final Owner authorization,
  // idempotency check and account insertion.
  const { data: accountId, error: createError } =
    await supabase.rpc("create_household_account", {
      p_household_id: membership.household_id,
      p_name: name,
      p_kind: rawKind,
      p_request_id: rawRequestId,
    });

  if (createError) {
    if (createError.code === "23505") {
      return failure(
        "Тази заявка вече е обработена с различни данни."
      );
    }

    if (createError.code === "42501") {
      return failure(
        "Нямаш разрешение за тази операция."
      );
    }

    return failure(
      "Създаването на сметката е неуспешно."
    );
  }

  if (typeof accountId !== "string") {
    return failure(
      "Неуспешно потвърждение от базата данни."
    );
  }

  revalidatePath("/admin");

  return {
    status: "success",
    message: "Сметката е създадена успешно.",
    accountId,
  };
}

export type AccountManagementState = {
  status: "idle" | "success" | "error";
  message: string;
  accountId: string | null;
};

type AccountOperation = "rename" | "close";

function managementFailure(
  message: string
): AccountManagementState {
  return {
    status: "error",
    message,
    accountId: null,
  };
}

export async function manageAccountAction(
  _previousState: AccountManagementState,
  formData: FormData
): Promise<AccountManagementState> {
  const supabase = await createClient();

  // Verify authentication for every mutation.
  const { data: auth, error: authError } =
    await supabase.auth.getClaims();

  if (authError || !auth?.claims?.sub) {
    redirect("/login");
  }

  const userId = auth.claims.sub;

  // Resolve household from the authenticated Owner.
  // Never accept a household ID from the browser.
  const { data: membership, error: membershipError } =
    await supabase
      .from("household_members")
      .select("household_id")
      .eq("user_id", userId)
      .eq("role", "owner")
      .eq("status", "active")
      .limit(1)
      .maybeSingle();

  if (membershipError || !membership) {
    return managementFailure(
      "Нямаш активни Owner права."
    );
  }

  const rawAccountId = formData.get("accountId");
  const rawOperation = formData.get("operation");

  if (
    typeof rawAccountId !== "string" ||
    !uuidPattern.test(rawAccountId)
  ) {
    return managementFailure(
      "Невалиден идентификатор на сметката."
    );
  }

  // Only supported lifecycle actions.
  // Archive and restore are no longer accepted.
  if (
    rawOperation !== "rename" &&
    rawOperation !== "close"
  ) {
    return managementFailure(
      "Невалидно административно действие."
    );
  }

  const operation: AccountOperation = rawOperation;

  let name: string | null = null;

  if (operation === "rename") {
    const rawName = formData.get("name");

    if (typeof rawName !== "string") {
      return managementFailure(
        "Въведи име на сметката."
      );
    }

    name = rawName.trim();

    if (
      name.length === 0 ||
      Array.from(name).length > 100
    ) {
      return managementFailure(
        "Името трябва да съдържа от 1 до 100 символа."
      );
    }
  }

  if (operation === "close") {
    const confirmationName =
      formData.get("confirmationName");

    if (typeof confirmationName !== "string") {
      return managementFailure(
        "Потвърди името на сметката."
      );
    }

    // Read the current database value.
    // Never rely on the name displayed in the browser.
    const { data: account, error: accountError } =
      await supabase
        .from("accounts")
        .select("name, status")
        .eq("household_id", membership.household_id)
        .eq("id", rawAccountId)
        .maybeSingle();

    if (accountError || !account) {
      return managementFailure(
        "Сметката не е открита или нямаш достъп."
      );
    }

    if (account.status !== "active") {
      return managementFailure(
        "Сметката вече е закрита."
      );
    }

    if (confirmationName !== account.name) {
      return managementFailure(
        "Името за потвърждение не съвпада " +
        "с актуалното име на сметката."
      );
    }
  }

  let operationError: {
    code?: string;
  } | null = null;

  if (operation === "close") {
    // PostgreSQL checks Owner permissions,
    // account balance and future movements.
    const { error } = await supabase.rpc(
      "close_household_account",
      {
        p_household_id: membership.household_id,
        p_account_id: rawAccountId,
      }
    );

    operationError = error;
  } else {
    // Rename is the only remaining management action.
    const { error } = await supabase.rpc(
      "manage_household_account",
      {
        p_household_id: membership.household_id,
        p_account_id: rawAccountId,
        p_action: "rename",
        p_name: name,
      }
    );

    operationError = error;
  }

  if (operationError) {
    if (operationError.code === "42501") {
      return managementFailure(
        "Нямаш разрешение за тази операция."
      );
    }

    if (
      operation === "close" &&
      operationError.code === "23514"
    ) {
      return managementFailure(
        "Сметката не може да бъде закрита. " +
        "Провери остатъка и бъдещите финансови движения."
      );
    }

    return managementFailure(
      "Административната операция е неуспешна."
    );
  }

  revalidatePath("/admin");

  const successMessages: Record<
    AccountOperation,
    string
  > = {
    rename: "Сметката е преименувана успешно.",
    close: "Сметката е закрита успешно.",
  };

  return {
    status: "success",
    message: successMessages[operation],
    accountId: rawAccountId,
  };
}