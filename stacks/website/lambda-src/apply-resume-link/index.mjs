import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand } from "@aws-sdk/lib-dynamodb";
import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const s3 = new S3Client({});

// Keeps the link HR clicks short and stable (an email with a ~1,700-char
// presigned URL wraps badly and looks like spam) -- this resolves the short
// link to a fresh 5-minute presigned S3 URL on every click instead.
export const handler = async (event) => {
  const id = event.pathParameters?.id;
  if (!id) return { statusCode: 400, body: "Missing application id." };

  const res = await ddb.send(new GetCommand({ TableName: process.env.APPLICATIONS_TABLE, Key: { id } }));
  if (!res.Item) return { statusCode: 404, body: "Application not found." };

  const url = await getSignedUrl(s3, new GetObjectCommand({ Bucket: process.env.RESUMES_BUCKET, Key: res.Item.resumeKey }), {
    expiresIn: 300,
  });

  return { statusCode: 302, headers: { Location: url } };
};
