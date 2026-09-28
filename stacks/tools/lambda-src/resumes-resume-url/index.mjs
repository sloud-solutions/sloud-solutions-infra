import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand } from "@aws-sdk/lib-dynamodb";
import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { json, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const s3 = new S3Client({});

// Mints a fresh, short-lived presigned S3 GET URL on demand instead of ever
// exposing a long-lived one to the browser -- same approach as the public
// apply-resume-link redirect Lambda, but returns JSON (this is an
// authenticated API call from the HRMS page, not an email link).
export const handler = async (event) => {
  const { role } = await callerAccess(event, ddb);
  if (role !== "Admin") {
    return json(403, { message: "Admin access only." });
  }

  const id = event.pathParameters?.id;
  if (!id) return json(400, { message: "Missing application id." });

  const res = await ddb.send(new GetCommand({ TableName: process.env.APPLICATIONS_TABLE, Key: { id } }));
  if (!res.Item) return json(404, { message: "No such application." });

  const url = await getSignedUrl(s3, new GetObjectCommand({ Bucket: process.env.RESUMES_BUCKET, Key: res.Item.resumeKey }), {
    expiresIn: 300,
  });

  return json(200, { url });
};
