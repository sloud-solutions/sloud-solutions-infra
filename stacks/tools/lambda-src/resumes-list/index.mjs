import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb";
import { json, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

// Admin-only, account-wide HR view over website-side job applications (see
// stacks/website's applications_table/resumes_bucket) -- not part of the
// per-employee page-access list, same idiom as cloud-resources-list.
export const handler = async (event) => {
  const { role } = await callerAccess(event, ddb);
  if (role !== "Admin") {
    return json(403, { message: "Admin access only." });
  }

  // No GSI on this table (it's a simple append-only inbox) -- a Scan is the
  // only option for "list everything", same as employees-list.
  const res = await ddb.send(new ScanCommand({ TableName: process.env.APPLICATIONS_TABLE }));
  const applications = (res.Items ?? []).map((item) => ({
    id: item.id,
    jobSlug: item.jobSlug,
    jobTitle: item.jobTitle,
    segment: item.segment,
    name: item.name,
    email: item.email,
    phone: item.phone,
    coverNote: item.coverNote ?? "",
    submittedAt: item.submittedAt,
    status: item.status ?? "pending",
    statusUpdatedAt: item.statusUpdatedAt ?? null,
    statusUpdatedBy: item.statusUpdatedBy ?? null,
  }));

  return json(200, { applications, count: applications.length });
};
