import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, DeleteCommand } from "@aws-sdk/lib-dynamodb";
import { CognitoIdentityProviderClient, AdminDisableUserCommand } from "@aws-sdk/client-cognito-identity-provider";
import { json, isAdmin, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const cognito = new CognitoIdentityProviderClient({});

// Only Admins may remove a team member (creating one is Admin-only too, via
// the separate admin-create-user Lambda) — viewing the directory only needs
// "employees" in the caller's access list, checked via callerAccess.
export const handler = async (event) => {
  await callerAccess(event, ddb); // ensures a caller identity resolves; role check below is explicit
  if (!isAdmin(event)) return json(403, { message: "Only Admins can remove a team member." });

  const method = event.requestContext.http.method;
  if (method !== "DELETE") return json(405, { message: "Method not allowed." });

  const id = event.pathParameters?.id;
  if (!id) return json(400, { message: "Missing id." });

  const existing = await ddb.send(new GetCommand({ TableName: process.env.EMPLOYEES_TABLE, Key: { id } }));
  if (existing.Item?.email) {
    try {
      await cognito.send(
        new AdminDisableUserCommand({ UserPoolId: process.env.USER_POOL_ID, Username: existing.Item.email }),
      );
    } catch {
      // If they never had a Cognito account (directory-only row) this is a no-op failure; proceed with the delete.
    }
  }

  await ddb.send(new DeleteCommand({ TableName: process.env.EMPLOYEES_TABLE, Key: { id } }));
  return json(204, {});
};
