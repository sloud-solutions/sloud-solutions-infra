import { randomUUID } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";
import {
  CognitoIdentityProviderClient,
  AdminCreateUserCommand,
  AdminSetUserPasswordCommand,
  AdminAddUserToGroupCommand,
} from "@aws-sdk/client-cognito-identity-provider";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { json, ALL_PAGES, isAdmin, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const cognito = new CognitoIdentityProviderClient({});
const s3 = new S3Client({});

const DATA_URL_RE = /^data:(image\/(?:jpeg|png));base64,(.+)$/;

/** Uploads an optional small canvas-resized photo (data URL) and returns its public CloudFront URL, or "". */
async function uploadPhoto(employeeId, photoDataUrl) {
  if (!photoDataUrl) return "";
  const match = DATA_URL_RE.exec(photoDataUrl);
  if (!match) return ""; // silently skip a malformed/oversized value rather than fail the whole request
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

const REQUIRED_FIELDS = ["name", "role", "type", "workingMode", "email", "joined", "accountRole", "password"];

// Admin-only: creates both the Cognito login and the Employees directory row,
// together. The Admin sets the initial password directly (rather than relying
// on Cognito's email invite) since these addresses aren't real mailboxes yet
// -- share the password with the person out-of-band (chat, in person, etc.).
export const handler = async (event) => {
  await callerAccess(event, ddb);
  if (!isAdmin(event)) return json(403, { message: "Only Admins can add a new team member." });

  let body;
  try {
    body = JSON.parse(event.body || "{}");
  } catch {
    return json(400, { message: "Invalid JSON body." });
  }
  const missing = REQUIRED_FIELDS.filter((f) => !body[f]);
  if (missing.length) return json(400, { message: `Missing field(s): ${missing.join(", ")}` });
  if (!["Admin", "Employee"].includes(body.accountRole)) return json(400, { message: "accountRole must be Admin or Employee." });

  const access = body.accountRole === "Admin" ? ALL_PAGES : Array.isArray(body.access) ? body.access.filter((p) => ALL_PAGES.includes(p)) : [];

  try {
    await cognito.send(
      new AdminCreateUserCommand({
        UserPoolId: process.env.USER_POOL_ID,
        Username: body.email,
        MessageAction: "SUPPRESS",
        UserAttributes: [
          { Name: "email", Value: body.email },
          { Name: "email_verified", Value: "true" },
        ],
      }),
    );
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
    if (err.name === "UsernameExistsException") return json(409, { message: "That email is already registered." });
    throw err;
  }
  await cognito.send(
    new AdminAddUserToGroupCommand({
      UserPoolId: process.env.USER_POOL_ID,
      Username: body.email,
      GroupName: body.accountRole,
    }),
  );

  const id = randomUUID();
  const photo = await uploadPhoto(id, body.photoDataUrl);

  const item = {
    id,
    name: String(body.name),
    role: String(body.role),
    type: String(body.type),
    skills: Array.isArray(body.skills) ? body.skills.map(String) : [],
    workingMode: String(body.workingMode),
    email: String(body.email),
    phone: String(body.phone ?? ""),
    location: String(body.location ?? ""),
    joined: String(body.joined),
    photo,
    workDashboard: String(body.workDashboard ?? ""),
    accountRole: body.accountRole,
    access,
    enabled: true,
  };
  await ddb.send(new PutCommand({ TableName: process.env.EMPLOYEES_TABLE, Item: item }));

  return json(201, item);
};
