import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand } from "@aws-sdk/lib-dynamodb";
import { json, callerEmail, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

const STATUSES = ["Available", "Not Available"];
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

// One row per employee per day (id = `${employeeId}#${date}`), so re-submitting
// the same day's entry upserts it in place rather than creating a duplicate.
export const handler = async (event) => {
  const { role, access, employeeId, name } = await callerAccess(event, ddb);
  if (role !== "Admin" && !access.includes("attendance")) {
    return json(403, { message: "No access to the Attendance Tracker." });
  }
  if (!employeeId) {
    return json(400, { message: "Your account isn't linked to an employee record. Ask an Admin to add your Employee ID." });
  }

  if (event.requestContext.http.method !== "POST") {
    return json(405, { message: "Method not allowed." });
  }

  let body;
  try {
    body = JSON.parse(event.body || "{}");
  } catch {
    return json(400, { message: "Invalid JSON body." });
  }

  const date = String(body.date ?? "");
  if (!DATE_RE.test(date)) return json(400, { message: "A valid date is required." });

  const status = String(body.status ?? "");
  if (!STATUSES.includes(status)) return json(400, { message: "Status must be Available or Not Available." });

  const hoursWorked = Number(body.hoursWorked);
  const workSummary = String(body.workSummary ?? "").trim();
  const reason = String(body.reason ?? "").trim();

  if (status === "Available") {
    if (!Number.isFinite(hoursWorked) || hoursWorked <= 0 || hoursWorked > 24) {
      return json(400, { message: "Hours worked must be a number between 0 and 24." });
    }
    if (!workSummary) return json(400, { message: "Please describe what you worked on." });
  } else if (!reason) {
    return json(400, { message: "Please give a reason." });
  }

  const id = `${employeeId}#${date}`;
  const existing = await ddb.send(new GetCommand({ TableName: process.env.ATTENDANCE_TABLE, Key: { id } }));

  const item = {
    id,
    employeeId,
    employeeName: name,
    date,
    status,
    hoursWorked: status === "Available" ? hoursWorked : 0,
    workSummary: status === "Available" ? workSummary : "",
    reason: status === "Not Available" ? reason : "",
    createdBy: callerEmail(event) ?? "unknown",
    createdAt: existing.Item?.createdAt ?? new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };

  await ddb.send(new PutCommand({ TableName: process.env.ATTENDANCE_TABLE, Item: item }));
  return json(existing.Item ? 200 : 201, item);
};
