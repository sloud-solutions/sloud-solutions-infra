import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand } from "@aws-sdk/lib-dynamodb";
import { json, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

// Admin-only, same as cloud-resources-list. Deliberately reads ONLY the
// cache item written by the separately-scheduled cost-poller Lambda -- this
// handler never calls Cost Explorer itself, so viewing this page (however
// often, by however many Admins) never adds to the metered $0.01/request
// Cost Explorer bill. Freshness is bounded by the poller's schedule, not by
// page views.
export const handler = async (event) => {
  const { role } = await callerAccess(event, ddb);
  if (role !== "Admin") {
    return json(403, { message: "Admin access only." });
  }

  const res = await ddb.send(new GetCommand({ TableName: process.env.COST_CACHE_TABLE, Key: { id: "current" } }));
  if (!res.Item) {
    return json(200, { total: 0, currency: "USD", byService: [], budget: null, updatedAt: null });
  }
  return json(200, res.Item);
};
