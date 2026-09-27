import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb";
import { json, callerAccess, callerEmail } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

export const handler = async (event) => {
  const { role, access } = await callerAccess(event, ddb);
  if (role !== "Admin" && !access.includes("work-tracker")) {
    return json(403, { message: "No access to the Work Tracker." });
  }
  const email = callerEmail(event);

  const res = await ddb.send(new ScanCommand({ TableName: process.env.WORK_BOARDS_TABLE }));
  const items = res.Items ?? [];
  const visible = role === "Admin" ? items : items.filter((b) => b.owner === email || (b.members ?? []).includes(email));
  return json(200, visible);
};
