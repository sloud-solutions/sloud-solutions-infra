import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, ScanCommand, UpdateCommand, DeleteCommand } from "@aws-sdk/lib-dynamodb";
import {
  CognitoIdentityProviderClient,
  AdminEnableUserCommand,
  AdminDisableUserCommand,
  AdminUserGlobalSignOutCommand,
  AdminAddUserToGroupCommand,
  AdminRemoveUserFromGroupCommand,
} from "@aws-sdk/client-cognito-identity-provider";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { json, ALL_PAGES, isAdmin, callerEmail, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const cognito = new CognitoIdentityProviderClient({});
const s3 = new S3Client({});

const DATA_URL_RE = /^data:(image\/(?:jpeg|png));base64,(.+)$/;

/** Uploads an optional small canvas-resized photo (data URL) and returns its public CloudFront URL, or "". */
async function uploadPhoto(employeeId, photoDataUrl) {
  if (!photoDataUrl) return null;
  const match = DATA_URL_RE.exec(photoDataUrl);
  if (!match) return null;
  const [, contentType, base64] = match;
  const ext = contentType === "image/png" ? "png" : "jpg";
  const objectKey = `photos/${employeeId}.${ext}`;
  await s3.send(
    new PutObjectCommand({
      Bucket: process.env.PHOTOS_BUCKET,
      Key: objectKey,
      Body: Buffer.from(base64, "base64"),
      ContentType: contentType,
    }),
  );
  return `https://${process.env.PHOTOS_DOMAIN}/${objectKey}`;
}

/** True row.enabled is only ever explicitly false; missing/undefined means enabled (default). */
const isEnabled = (row) => row.enabled !== false;

/** Whether at least one *other* enabled Admin exists besides `excludeId`. */
async function anotherActiveAdminExists(excludeId) {
  const res = await ddb.send(
    new ScanCommand({
      TableName: process.env.EMPLOYEES_TABLE,
      FilterExpression: "accountRole = :admin",
      ExpressionAttributeValues: { ":admin": "Admin" },
    }),
  );
  return (res.Items ?? []).some((row) => row.id !== excludeId && isEnabled(row));
}

const EDITABLE_FIELDS = ["name", "role", "type", "skills", "workingMode", "phone", "location", "joined", "workDashboard"];

// Only Admins may edit, enable/disable, or remove a team member (creating one
// is Admin-only too, via the separate admin-create-user Lambda) -- viewing
// the directory only needs "employees" in the caller's access list, checked
// via callerAccess.
export const handler = async (event) => {
  await callerAccess(event, ddb); // ensures a caller identity resolves; role check below is explicit
  if (!isAdmin(event)) return json(403, { message: "Only Admins can edit, enable/disable, or remove a team member." });

  const method = event.requestContext.http.method;
  const id = event.pathParameters?.id;
  if (!id) return json(400, { message: "Missing id." });
  const myEmail = callerEmail(event);

  if (method === "DELETE") {
    const existing = await ddb.send(new GetCommand({ TableName: process.env.EMPLOYEES_TABLE, Key: { id } }));
    if (!existing.Item) return json(404, { message: "No such employee." });

    if (existing.Item.email && existing.Item.email === myEmail) {
      return json(400, { message: "You can't remove your own account while logged in as them. Ask another Admin, or use Disable instead." });
    }
    if (existing.Item.accountRole === "Admin" && !(await anotherActiveAdminExists(id))) {
      return json(400, { message: "Can't remove the last active Admin. Make someone else an Admin first." });
    }

    if (existing.Item.email) {
      try {
        await cognito.send(new AdminDisableUserCommand({ UserPoolId: process.env.USER_POOL_ID, Username: existing.Item.email }));
      } catch {
        // If they never had a Cognito account (directory-only row) this is a no-op failure; proceed with the delete.
      }
    }
    await ddb.send(new DeleteCommand({ TableName: process.env.EMPLOYEES_TABLE, Key: { id } }));
    return json(204, {});
  }

  if (method === "PATCH") {
    let body;
    try {
      body = JSON.parse(event.body || "{}");
    } catch {
      return json(400, { message: "Invalid JSON body." });
    }

    const existing = await ddb.send(new GetCommand({ TableName: process.env.EMPLOYEES_TABLE, Key: { id } }));
    if (!existing.Item) return json(404, { message: "No such employee." });

    const names = {};
    const values = {};
    const sets = [];
    for (const field of EDITABLE_FIELDS) {
      if (body[field] === undefined) continue;
      names[`#${field}`] = field;
      values[`:${field}`] = field === "skills" ? (Array.isArray(body.skills) ? body.skills.map(String) : []) : String(body[field]);
      sets.push(`#${field} = :${field}`);
    }

    if (body.accountRole !== undefined) {
      if (!["Admin", "Employee"].includes(body.accountRole)) return json(400, { message: "accountRole must be Admin or Employee." });
      if (existing.Item.accountRole === "Admin" && body.accountRole !== "Admin" && !(await anotherActiveAdminExists(id))) {
        return json(400, { message: "Can't demote the last active Admin. Make someone else an Admin first." });
      }
      const access = body.accountRole === "Admin" ? ALL_PAGES : Array.isArray(body.access) ? body.access.filter((p) => ALL_PAGES.includes(p)) : [];
      names["#accountRole"] = "accountRole";
      names["#access"] = "access";
      values[":accountRole"] = body.accountRole;
      values[":access"] = access;
      sets.push("#accountRole = :accountRole", "#access = :access");

      if (body.accountRole !== existing.Item.accountRole) {
        await cognito.send(
          new AdminRemoveUserFromGroupCommand({ UserPoolId: process.env.USER_POOL_ID, Username: existing.Item.email, GroupName: existing.Item.accountRole }),
        );
        await cognito.send(
          new AdminAddUserToGroupCommand({ UserPoolId: process.env.USER_POOL_ID, Username: existing.Item.email, GroupName: body.accountRole }),
        );
      }
    }

    if (body.enabled !== undefined) {
      if (typeof body.enabled !== "boolean") return json(400, { message: "enabled must be true or false." });
      if (!body.enabled) {
        if (existing.Item.email && existing.Item.email === myEmail) {
          return json(400, { message: "You can't disable your own account while logged in as them." });
        }
        if (existing.Item.accountRole === "Admin" && !(await anotherActiveAdminExists(id))) {
          return json(400, { message: "Can't disable the last active Admin. Make someone else an Admin first." });
        }
      }
      names["#enabled"] = "enabled";
      values[":enabled"] = body.enabled;
      sets.push("#enabled = :enabled");

      if (existing.Item.email) {
        if (body.enabled) {
          await cognito.send(new AdminEnableUserCommand({ UserPoolId: process.env.USER_POOL_ID, Username: existing.Item.email }));
        } else {
          await cognito.send(new AdminDisableUserCommand({ UserPoolId: process.env.USER_POOL_ID, Username: existing.Item.email }));
          try {
            // Revokes any tokens/session already issued, so a disable takes effect immediately.
            await cognito.send(new AdminUserGlobalSignOutCommand({ UserPoolId: process.env.USER_POOL_ID, Username: existing.Item.email }));
          } catch {}
        }
      }
    }

    const photo = await uploadPhoto(id, body.photoDataUrl);
    if (photo) {
      names["#photo"] = "photo";
      values[":photo"] = photo;
      sets.push("#photo = :photo");
    }

    if (!sets.length) return json(400, { message: "Nothing to update." });

    const res = await ddb.send(
      new UpdateCommand({
        TableName: process.env.EMPLOYEES_TABLE,
        Key: { id },
        UpdateExpression: `SET ${sets.join(", ")}`,
        ExpressionAttributeNames: names,
        ExpressionAttributeValues: values,
        ReturnValues: "ALL_NEW",
      }),
    );
    return json(200, res.Attributes);
  }

  return json(405, { message: "Method not allowed." });
};
