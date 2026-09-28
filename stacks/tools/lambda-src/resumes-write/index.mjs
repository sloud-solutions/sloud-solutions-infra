import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, UpdateCommand, DeleteCommand } from "@aws-sdk/lib-dynamodb";
import { S3Client, DeleteObjectCommand } from "@aws-sdk/client-s3";
import { json, callerEmail, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const s3 = new S3Client({});

const STATUSES = new Set(["pending", "consider", "not_consider"]);

export const handler = async (event) => {
  const { role } = await callerAccess(event, ddb);
  if (role !== "Admin") {
    return json(403, { message: "Admin access only." });
  }

  const method = event.requestContext.http.method;
  const id = event.pathParameters?.id;
  if (!id) return json(400, { message: "Missing application id." });

  if (method === "DELETE") {
    const existing = await ddb.send(new GetCommand({ TableName: process.env.APPLICATIONS_TABLE, Key: { id } }));
    if (!existing.Item) return json(404, { message: "No such application." });

    if (existing.Item.resumeKey) {
      // Best-effort -- if the object is already gone, still proceed to
      // remove the DynamoDB row rather than leaving an orphaned reference.
      try {
        await s3.send(new DeleteObjectCommand({ Bucket: process.env.RESUMES_BUCKET, Key: existing.Item.resumeKey }));
      } catch (err) {
        console.error("resume object delete failed", err);
      }
    }

    await ddb.send(new DeleteCommand({ TableName: process.env.APPLICATIONS_TABLE, Key: { id } }));
    return json(204, {});
  }

  if (method === "PATCH") {
    let body;
    try {
      body = JSON.parse(event.body || "{}");
    } catch {
      return json(400, { message: "Invalid JSON body." });
    }

    if (!STATUSES.has(body.status)) {
      return json(400, { message: "status must be pending, consider, or not_consider." });
    }

    const existing = await ddb.send(new GetCommand({ TableName: process.env.APPLICATIONS_TABLE, Key: { id } }));
    if (!existing.Item) return json(404, { message: "No such application." });

    const res = await ddb.send(
      new UpdateCommand({
        TableName: process.env.APPLICATIONS_TABLE,
        Key: { id },
        UpdateExpression: "SET #status = :status, statusUpdatedAt = :at, statusUpdatedBy = :by",
        ExpressionAttributeNames: { "#status": "status" },
        ExpressionAttributeValues: {
          ":status": body.status,
          ":at": new Date().toISOString(),
          ":by": callerEmail(event) ?? "",
        },
        ReturnValues: "ALL_NEW",
      }),
    );
    return json(200, res.Attributes);
  }

  return json(405, { message: "Method not allowed." });
};
