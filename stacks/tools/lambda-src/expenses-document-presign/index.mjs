import { randomUUID } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient } from "@aws-sdk/lib-dynamodb";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { json, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const s3 = new S3Client({});

// Bills/receipts can be a scanned PDF, not just a small canvas-resized
// photo, so (unlike the employee-photo flow) this goes through S3 directly
// via a presigned URL rather than inline base64 in the create-expense body.
const MAX_BYTES = 5 * 1024 * 1024; // 5 MB fixed cap
const ALLOWED_TYPES = { "application/pdf": "pdf", "image/jpeg": "jpg", "image/png": "png" };

export const handler = async (event) => {
  const { role, access } = await callerAccess(event, ddb);
  if (role !== "Admin" && !access.includes("expenses")) {
    return json(403, { message: "No access to the Expense Tracker." });
  }

  let body;
  try {
    body = JSON.parse(event.body || "{}");
  } catch {
    return json(400, { message: "Invalid JSON body." });
  }

  const contentType = body.contentType;
  const sizeBytes = Number(body.sizeBytes);
  const ext = ALLOWED_TYPES[contentType];
  if (!ext) return json(400, { message: "Only PDF, JPEG, or PNG files are accepted." });
  if (!Number.isFinite(sizeBytes) || sizeBytes <= 0) return json(400, { message: "Missing file size." });
  if (sizeBytes > MAX_BYTES) return json(400, { message: `File is too large -- the limit is ${MAX_BYTES / (1024 * 1024)} MB.` });

  const objectKey = `documents/${randomUUID()}.${ext}`;
  const uploadUrl = await getSignedUrl(
    s3,
    new PutObjectCommand({ Bucket: process.env.PHOTOS_BUCKET, Key: objectKey, ContentType: contentType, ContentLength: sizeBytes }),
    { expiresIn: 300 },
  );

  return json(200, { uploadUrl, documentUrl: `https://${process.env.PHOTOS_DOMAIN}/${objectKey}` });
};
