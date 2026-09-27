// Shared helpers for reading the caller's role/access out of the Cognito JWT
// (passed through by API Gateway's JWT authorizer) and, for non-Admins, their
// per-page access list on the Employees table. Duplicated (not imported)
// across each Lambda's own directory, since each is zipped independently.
import { DynamoDBDocumentClient, QueryCommand } from "@aws-sdk/lib-dynamodb";

export const ALL_PAGES = ["offer-letter", "company-policy", "clients", "expenses", "employees"];

export function json(statusCode, body) {
  return { statusCode, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) };
}

export function claims(event) {
  return event.requestContext?.authorizer?.jwt?.claims ?? {};
}

export function isAdmin(event) {
  const groups = claims(event)["cognito:groups"];
  const list = Array.isArray(groups) ? groups : typeof groups === "string" ? groups.split(",") : [];
  return list.includes("Admin");
}

export function callerEmail(event) {
  return claims(event).email;
}

/** Admins implicitly have every page; everyone else is whatever's on their Employees row. */
export async function callerAccess(event, ddb) {
  if (isAdmin(event)) return { role: "Admin", access: ALL_PAGES };
  const email = callerEmail(event);
  if (!email) return { role: "Employee", access: [] };
  const res = await ddb.send(
    new QueryCommand({
      TableName: process.env.EMPLOYEES_TABLE,
      IndexName: process.env.EMPLOYEES_EMAIL_INDEX,
      KeyConditionExpression: "email = :e",
      ExpressionAttributeValues: { ":e": email },
      Limit: 1,
    }),
  );
  const row = res.Items?.[0];
  return { role: row?.accountRole ?? "Employee", access: row?.access ?? [] };
}
