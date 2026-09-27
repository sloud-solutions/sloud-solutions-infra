import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb";
import { json, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

export const handler = async (event) => {
  const { role, access } = await callerAccess(event, ddb);
  const canSeeDirectory = role === "Admin" || access.includes("employees");
  if (!canSeeDirectory && !access.includes("expenses") && !access.includes("work-tracker")) {
    return json(403, { message: "No access to the Employees directory." });
  }

  const res = await ddb.send(new ScanCommand({ TableName: process.env.EMPLOYEES_TABLE }));
  const items = res.Items ?? [];
  if (canSeeDirectory) return json(200, items);

  // Expense/Work-Tracker-only callers only get the minimal shape needed for
  // their "paid by"/assignee/board-member pickers, not the full directory
  // (phone, location, skills, etc.). Email is included because board
  // membership and task assignment are keyed by email, same as the caller's
  // own identity from the JWT.
  const minimal = items
    .filter((e) => e.enabled !== false)
    .map((e) => ({ id: e.id, employeeId: e.employeeId ?? "", name: e.name, email: e.email }));
  return json(200, minimal);
};
