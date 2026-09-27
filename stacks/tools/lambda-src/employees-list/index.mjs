import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb";
import { json, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

export const handler = async (event) => {
  const { role, access } = await callerAccess(event, ddb);
  if (role !== "Admin" && !access.includes("employees")) {
    return json(403, { message: "No access to the Employees directory." });
  }

  const res = await ddb.send(new ScanCommand({ TableName: process.env.EMPLOYEES_TABLE }));
  return json(200, res.Items ?? []);
};
