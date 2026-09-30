import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { json, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

export const handler = async (event) => {
  const { role, access, employeeId } = await callerAccess(event, ddb);
  if (role !== "Admin" && !access.includes("attendance")) {
    return json(403, { message: "No access to the Attendance Tracker." });
  }

  // Admins see every employee's records (for the consolidated view);
  // everyone else only ever sees their own.
  if (role === "Admin") {
    const res = await ddb.send(new ScanCommand({ TableName: process.env.ATTENDANCE_TABLE }));
    return json(200, res.Items ?? []);
  }

  if (!employeeId) return json(200, []);

  const res = await ddb.send(
    new QueryCommand({
      TableName: process.env.ATTENDANCE_TABLE,
      IndexName: process.env.ATTENDANCE_EMPLOYEE_INDEX,
      KeyConditionExpression: "employeeId = :e",
      ExpressionAttributeValues: { ":e": employeeId },
    }),
  );
  return json(200, res.Items ?? []);
};
