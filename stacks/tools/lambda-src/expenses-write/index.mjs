import { randomUUID } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand, DeleteCommand, GetCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { json, claims, callerEmail, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

const REQUIRED_FIELDS = ["date", "item", "vendor", "category", "amount", "paidBy", "status", "expiryDate", "autoRenewal"];
const EDITABLE_FIELDS = ["date", "item", "vendor", "category", "amount", "paidBy", "status", "notes", "expiryDate", "autoRenewal", "documentUrl", "documentName"];

export const handler = async (event) => {
  const { role, access } = await callerAccess(event, ddb);
  if (role !== "Admin" && !access.includes("expenses")) {
    return json(403, { message: "No access to the Expense Tracker." });
  }

  const method = event.requestContext.http.method;

  if (method === "POST") {
    let body;
    try {
      body = JSON.parse(event.body || "{}");
    } catch {
      return json(400, { message: "Invalid JSON body." });
    }
    const missing = REQUIRED_FIELDS.filter((f) => body[f] === undefined || body[f] === "");
    if (missing.length) return json(400, { message: `Missing field(s): ${missing.join(", ")}` });
    if (!["Yes", "No"].includes(body.autoRenewal)) return json(400, { message: "autoRenewal must be Yes or No." });

    const item = {
      id: randomUUID(),
      date: String(body.date),
      item: String(body.item),
      vendor: String(body.vendor),
      category: String(body.category),
      amount: Number(body.amount),
      paidBy: String(body.paidBy),
      status: String(body.status),
      notes: String(body.notes ?? ""),
      expiryDate: String(body.expiryDate),
      autoRenewal: body.autoRenewal,
      documentUrl: String(body.documentUrl ?? ""),
      documentName: String(body.documentName ?? ""),
      createdBy: callerEmail(event) ?? "unknown",
      createdAt: new Date().toISOString(),
    };
    if (!Number.isFinite(item.amount) || item.amount <= 0) return json(400, { message: "Amount must be a positive number." });

    await ddb.send(new PutCommand({ TableName: process.env.EXPENSES_TABLE, Item: item }));
    return json(201, item);
  }

  if (method === "DELETE") {
    const id = event.pathParameters?.id;
    if (!id) return json(400, { message: "Missing id." });
    await ddb.send(new DeleteCommand({ TableName: process.env.EXPENSES_TABLE, Key: { id } }));
    return json(204, {});
  }

  if (method === "PATCH") {
    const id = event.pathParameters?.id;
    if (!id) return json(400, { message: "Missing id." });

    let body;
    try {
      body = JSON.parse(event.body || "{}");
    } catch {
      return json(400, { message: "Invalid JSON body." });
    }

    const existing = await ddb.send(new GetCommand({ TableName: process.env.EXPENSES_TABLE, Key: { id } }));
    if (!existing.Item) return json(404, { message: "No such expense." });

    if (body.autoRenewal !== undefined && !["Yes", "No"].includes(body.autoRenewal)) {
      return json(400, { message: "autoRenewal must be Yes or No." });
    }
    if (body.amount !== undefined && (!Number.isFinite(Number(body.amount)) || Number(body.amount) <= 0)) {
      return json(400, { message: "Amount must be a positive number." });
    }

    const names = {};
    const values = {};
    const sets = [];
    for (const field of EDITABLE_FIELDS) {
      if (body[field] === undefined) continue;
      names[`#${field}`] = field;
      values[`:${field}`] = field === "amount" ? Number(body.amount) : String(body[field]);
      sets.push(`#${field} = :${field}`);
    }
    if (!sets.length) return json(400, { message: "Nothing to update." });

    const res = await ddb.send(
      new UpdateCommand({
        TableName: process.env.EXPENSES_TABLE,
        Key: { id },
        UpdateExpression: `SET ${sets.join(", ")}`,
        ExpressionAttributeNames: names,
        ExpressionAttributeValues: values,
        ReturnValues: "ALL_NEW",
      }),
    );
    return json(200, res.Attributes);
  }

  return json(405, { message: "Method not allowed." });
};
