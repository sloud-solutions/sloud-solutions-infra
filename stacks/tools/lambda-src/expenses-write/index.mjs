import { randomUUID } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand, DeleteCommand } from "@aws-sdk/lib-dynamodb";
import { json, claims, callerEmail, callerAccess } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

const REQUIRED_FIELDS = ["date", "item", "vendor", "category", "amount", "paidBy", "status", "expiryDate", "autoRenewal"];

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

  return json(405, { message: "Method not allowed." });
};
