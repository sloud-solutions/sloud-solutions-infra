import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";
import { CostExplorerClient, GetCostAndUsageCommand } from "@aws-sdk/client-cost-explorer";
import { BudgetsClient, DescribeBudgetsCommand } from "@aws-sdk/client-budgets";
import { STSClient, GetCallerIdentityCommand } from "@aws-sdk/client-sts";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
// Cost Explorer and Budgets are both global/us-east-1-only APIs, regardless
// of which region this Lambda itself runs in.
const ce = new CostExplorerClient({ region: "us-east-1" });
const budgets = new BudgetsClient({ region: "us-east-1" });
const sts = new STSClient({});

function monthStart() {
  const d = new Date();
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-01`;
}
function today() {
  return new Date().toISOString().slice(0, 10);
}

// Runs on a fixed schedule (EventBridge), independent of page views -- this
// is the ONLY thing in this app that calls the metered Cost Explorer API
// ($0.01/request), so its cost is purely a function of the schedule's
// cadence, never of how often admins open the dashboard.
export const handler = async () => {
  const start = monthStart();
  const end = today();

  const usage = await ce.send(
    new GetCostAndUsageCommand({
      TimePeriod: { Start: start, End: end },
      Granularity: "MONTHLY",
      Metrics: ["UnblendedCost"],
      GroupBy: [{ Type: "DIMENSION", Key: "SERVICE" }],
    }),
  );

  const groups = usage.ResultsByTime?.[0]?.Groups ?? [];
  const byService = groups
    .map((g) => ({ service: g.Keys?.[0] ?? "Unknown", amount: Number(g.Metrics?.UnblendedCost?.Amount ?? 0) }))
    .filter((s) => s.amount !== 0)
    .sort((a, b) => b.amount - a.amount);
  const total = byService.reduce((sum, s) => sum + s.amount, 0);

  let budget = null;
  try {
    const { Account } = await sts.send(new GetCallerIdentityCommand({}));
    const res = await budgets.send(new DescribeBudgetsCommand({ AccountId: Account }));
    const b = res.Budgets?.[0];
    if (b) {
      budget = {
        name: b.BudgetName,
        limit: Number(b.BudgetLimit?.Amount ?? 0),
        unit: b.BudgetLimit?.Unit ?? "USD",
        period: b.TimeUnit,
        actualSpend: Number(b.CalculatedSpend?.ActualSpend?.Amount ?? 0),
      };
    }
  } catch (err) {
    // Budgets is optional context for the widget -- don't fail the whole
    // refresh if it's unavailable for any reason.
    console.error("budget lookup failed", err);
  }

  await ddb.send(
    new PutCommand({
      TableName: process.env.COST_CACHE_TABLE,
      Item: {
        id: "current",
        total,
        currency: "USD",
        byService,
        budget,
        periodStart: start,
        periodEnd: end,
        updatedAt: new Date().toISOString(),
      },
    }),
  );
};
