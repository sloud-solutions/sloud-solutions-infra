import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb";
import { json, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

export const handler = async (event) => {
  const { role, access } = await callerAccess(event, ddb);
  const canSeeDirectory = role === "Admin" || access.includes("employees");
  if (!canSeeDirectory && !access.includes("expenses")) {
    return json(403, { message: "No access to the Employees directory." });
  }

  const res = await ddb.send(new ScanCommand({ TableName: process.env.EMPLOYEES_TABLE }));
  const items = res.Items ?? [];
  if (canSeeDirectory) return json(200, items);

  // Expense-only callers only get the minimal shape needed for the "paid by"
  // dropdown, not the full directory (name, contact details, etc.).
  const minimal = items.filter((e) => e.enabled !== false).map((e) => ({ id: e.id, employeeId: e.employeeId ?? "", name: e.name }));
  return json(200, minimal);
};
