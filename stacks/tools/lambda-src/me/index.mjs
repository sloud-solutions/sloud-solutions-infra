import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient } from "@aws-sdk/lib-dynamodb";
import { json, callerEmail, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

// Called once right after login; drives the frontend's nav/page filtering.
export const handler = async (event) => {
  const { role, access, name, jobTitle } = await callerAccess(event, ddb);
  return json(200, { email: callerEmail(event) ?? null, role, access, name, jobTitle });
};
