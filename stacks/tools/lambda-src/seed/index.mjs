// One-off: invoked manually once after first deploy (not routed through API
// Gateway). Loads the same illustrative sample rows the app used to ship as
// hardcoded localStorage seed data. The first real Admin (e.g. Archana) is
// created separately, by hand, per the deploy runbook — not seeded here —
// so there's exactly one row for that real person, not a placeholder plus a
// real one.
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

const EXPENSES = [
  { id: "x1", date: "2026-09-02", item: "Domain renewal – sloudsolutions.com", vendor: "Namecheap", category: "Software", amount: 1299, paidBy: "Archana", status: "Paid", notes: "", createdBy: "seed", createdAt: new Date().toISOString() },
  { id: "x2", date: "2026-09-10", item: "AWS monthly bill", vendor: "Amazon Web Services", category: "Cloud / Hosting", amount: 2450, paidBy: "Company card", status: "Paid", notes: "August usage", createdBy: "seed", createdAt: new Date().toISOString() },
  { id: "x3", date: "2026-09-15", item: "Laptop for new intern", vendor: "Croma", category: "Hardware", amount: 48500, paidBy: "Archana", status: "Reimbursable", notes: "Invoice #4471", createdBy: "seed", createdAt: new Date().toISOString() },
  { id: "x4", date: "2026-09-21", item: "Google Workspace (3 seats)", vendor: "Google", category: "Software", amount: 1620, paidBy: "Company card", status: "Pending", notes: "", createdBy: "seed", createdAt: new Date().toISOString() },
];

const EMPLOYEES = [
  {
    id: "e2", name: "Sample Engineer (dummy)", role: "Cloud Engineer", type: "Full-time",
    skills: ["AWS", "Terraform", "CI/CD", "Docker"], workingMode: "Remote",
    email: "engineer@sloudsolutions.com", phone: "+00 000 000 0002", location: "Chennai, India",
    joined: "2025-03-10", photo: "", workDashboard: "", accountRole: "Employee", access: ["expenses"],
  },
  {
    id: "e3", name: "Sample Intern (dummy)", role: "Web Developer Intern", type: "Intern",
    skills: ["HTML", "Tailwind", "JavaScript"], workingMode: "On-site",
    email: "intern@sloudsolutions.com", phone: "+00 000 000 0003", location: "Bengaluru, India",
    joined: "2026-07-01", photo: "", workDashboard: "", accountRole: "Employee", access: ["clients"],
  },
];

async function putIfAbsent(tableName, item) {
  try {
    await ddb.send(
      new PutCommand({ TableName: tableName, Item: item, ConditionExpression: "attribute_not_exists(id)" }),
    );
    return "created";
  } catch (err) {
    if (err.name === "ConditionalCheckFailedException") return "skipped (already exists)";
    throw err;
  }
}

export const handler = async () => {
  const results = { expenses: {}, employees: {} };
  for (const item of EXPENSES) results.expenses[item.id] = await putIfAbsent(process.env.EXPENSES_TABLE, item);
  for (const item of EMPLOYEES) results.employees[item.id] = await putIfAbsent(process.env.EMPLOYEES_TABLE, item);
  return results;
};
