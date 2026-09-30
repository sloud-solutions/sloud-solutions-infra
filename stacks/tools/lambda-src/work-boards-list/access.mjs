// Shared helpers for reading the caller's role/access out of the Cognito JWT
// (passed through by API Gateway's JWT authorizer) and, for non-Admins, their
// per-page access list on the Employees table. Duplicated (not imported)
// across each Lambda's own directory, since each is zipped independently.
import { DynamoDBDocumentClient, QueryCommand } from "@aws-sdk/lib-dynamodb";

export const ALL_PAGES = ["offer-letter", "company-policy", "clients", "expenses", "employees", "work-tracker", "attendance"];

export function json(statusCode, body) {
  return { statusCode, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) };
}

export function claims(event) {
  return event.requestContext?.authorizer?.jwt?.claims ?? {};
}

export function isAdmin(event) {
  const raw = claims(event)["cognito:groups"];
  if (!raw) return false;
  // API Gateway's HTTP API JWT authorizer serializes an array claim as a
  // bracketed string, e.g. "[Admin]" or "[Admin, Employee]" -- not clean CSV.
  const list = Array.isArray(raw)
    ? raw
    : String(raw)
        .replace(/^\[|\]$/g, "")
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean);
  return list.includes("Admin");
}

export function callerEmail(event) {
  return claims(event).email;
}

/**
 * Always looks up the caller's Employees row (needed for `name` regardless of
 * role) -- but `role`/`access` for Admins still comes from the JWT group
 * claim, not the row, so an Admin never loses access just because their
 * directory row is missing or stale.
 */
export async function callerAccess(event, ddb) {
  const email = callerEmail(event);
  let row;
  if (email) {
    const res = await ddb.send(
      new QueryCommand({
        TableName: process.env.EMPLOYEES_TABLE,
        IndexName: process.env.EMPLOYEES_EMAIL_INDEX,
        KeyConditionExpression: "email = :e",
        ExpressionAttributeValues: { ":e": email },
        Limit: 1,
      }),
    );
    row = res.Items?.[0];
  }
  const admin = isAdmin(event);
  return {
    role: admin ? "Admin" : row?.accountRole ?? "Employee",
    access: admin ? ALL_PAGES : row?.access ?? [],
    name: row?.name ?? email ?? "",
    employeeId: row?.employeeId ?? "",
    jobTitle: row?.role ?? "",
    photo: row?.photo ?? "",
  };
}
