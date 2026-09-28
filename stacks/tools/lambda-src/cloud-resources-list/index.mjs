import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient } from "@aws-sdk/lib-dynamodb";
import { ResourceExplorer2Client, SearchCommand } from "@aws-sdk/client-resource-explorer-2";
import { json, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const explorer = new ResourceExplorer2Client({});

// Admin-only: this lists every resource across the whole AWS account, not
// just this app's own data, so it isn't part of the per-employee page-access
// list like the other pages -- only Admins (via the Cognito group claim) can
// call it, regardless of anyone's Employees-table access grants.
export const handler = async (event) => {
  const { role } = await callerAccess(event, ddb);
  if (role !== "Admin") {
    return json(403, { message: "Admin access only." });
  }

  const resources = [];
  let nextToken;
  do {
    const res = await explorer.send(new SearchCommand({ QueryString: "", MaxResults: 100, NextToken: nextToken }));
    for (const r of res.Resources ?? []) {
      resources.push({
        arn: r.Arn,
        resourceType: r.ResourceType,
        service: r.Service,
        region: r.Region,
        lastReportedAt: r.LastReportedAt,
      });
    }
    nextToken = res.NextToken;
  } while (nextToken && resources.length < 2000); // guard against a runaway account

  return json(200, { resources, count: resources.length, generatedAt: new Date().toISOString() });
};
