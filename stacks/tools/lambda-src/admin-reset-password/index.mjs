import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient } from "@aws-sdk/lib-dynamodb";
import { CognitoIdentityProviderClient, AdminSetUserPasswordCommand } from "@aws-sdk/client-cognito-identity-provider";
import { json, isAdmin, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const cognito = new CognitoIdentityProviderClient({});

// Admin-only: sets someone's password directly (no email dependency --
// these addresses aren't real mailboxes). Share the new password with them
// out-of-band.
export const handler = async (event) => {
  await callerAccess(event, ddb);
  if (!isAdmin(event)) return json(403, { message: "Only Admins can reset a password." });

  let body;
  try {
    body = JSON.parse(event.body || "{}");
  } catch {
    return json(400, { message: "Invalid JSON body." });
  }
  if (!body.email || !body.password) return json(400, { message: "Missing email or password." });

  try {
    await cognito.send(
      new AdminSetUserPasswordCommand({
        UserPoolId: process.env.USER_POOL_ID,
        Username: body.email,
        Password: body.password,
        Permanent: true,
      }),
    );
  } catch (err) {
    if (err.name === "InvalidPasswordException") return json(400, { message: err.message });
    if (err.name === "UserNotFoundException") return json(404, { message: "No login found for that email." });
    throw err;
  }

  return json(204, {});
};
