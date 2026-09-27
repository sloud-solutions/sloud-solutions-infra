import { randomUUID } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand, GetCommand, UpdateCommand, DeleteCommand } from "@aws-sdk/lib-dynamodb";
import { json, callerAccess, callerEmail } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const STATUSES = ["todo", "in-progress", "completed", "blocked"];
const EDITABLE_FIELDS = ["title", "description", "status", "assignee", "priority", "dueDate"];

/** Loads a board and checks membership: null = no such board, undefined = not a member, else the board. */
async function loadBoardForMember(boardId, role, email) {
  const board = await ddb.send(new GetCommand({ TableName: process.env.WORK_BOARDS_TABLE, Key: { id: boardId } }));
  if (!board.Item) return null;
  if (role !== "Admin" && board.Item.owner !== email && !(board.Item.members ?? []).includes(email)) return undefined;
  return board.Item;
}

export const handler = async (event) => {
  const { role, access } = await callerAccess(event, ddb);
  if (role !== "Admin" && !access.includes("work-tracker")) {
    return json(403, { message: "No access to the Work Tracker." });
  }
  const email = callerEmail(event);
  const method = event.requestContext.http.method;

  if (method === "POST") {
    const boardId = event.pathParameters?.boardId;
    if (!boardId) return json(400, { message: "Missing board id." });
    const board = await loadBoardForMember(boardId, role, email);
    if (board === null) return json(404, { message: "No such board." });
    if (board === undefined) return json(403, { message: "You're not a member of this board." });

    let body;
    try {
      body = JSON.parse(event.body || "{}");
    } catch {
      return json(400, { message: "Invalid JSON body." });
    }
    if (!body.title || !String(body.title).trim()) return json(400, { message: "Task title is required." });
    const status = STATUSES.includes(body.status) ? body.status : "todo";

    const item = {
      id: randomUUID(),
      boardId,
      title: String(body.title).trim(),
      description: String(body.description ?? "").trim(),
      status,
      assignee: String(body.assignee ?? ""),
      priority: String(body.priority ?? ""),
      dueDate: String(body.dueDate ?? ""),
      createdBy: email ?? "unknown",
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    await ddb.send(new PutCommand({ TableName: process.env.WORK_TASKS_TABLE, Item: item }));
    return json(201, item);
  }

  const id = event.pathParameters?.id;
  if (!id) return json(400, { message: "Missing id." });
  const existing = await ddb.send(new GetCommand({ TableName: process.env.WORK_TASKS_TABLE, Key: { id } }));
  if (!existing.Item) return json(404, { message: "No such task." });
  const board = await loadBoardForMember(existing.Item.boardId, role, email);
  if (board === null) return json(404, { message: "No such board." });
  if (board === undefined) return json(403, { message: "You're not a member of this board." });

  if (method === "PATCH") {
    let body;
    try {
      body = JSON.parse(event.body || "{}");
    } catch {
      return json(400, { message: "Invalid JSON body." });
    }
    if (body.status !== undefined && !STATUSES.includes(body.status)) {
      return json(400, { message: `status must be one of: ${STATUSES.join(", ")}.` });
    }
    if (body.title !== undefined && !String(body.title).trim()) {
      return json(400, { message: "Task title is required." });
    }

    const names = {};
    const values = {};
    const sets = [];
    for (const field of EDITABLE_FIELDS) {
      if (body[field] === undefined) continue;
      names[`#${field}`] = field;
      values[`:${field}`] = String(body[field]);
      sets.push(`#${field} = :${field}`);
    }
    if (!sets.length) return json(400, { message: "Nothing to update." });
    names["#updatedAt"] = "updatedAt";
    values[":updatedAt"] = new Date().toISOString();
    sets.push("#updatedAt = :updatedAt");

    const res = await ddb.send(
      new UpdateCommand({
        TableName: process.env.WORK_TASKS_TABLE,
        Key: { id },
        UpdateExpression: `SET ${sets.join(", ")}`,
        ExpressionAttributeNames: names,
        ExpressionAttributeValues: values,
        ReturnValues: "ALL_NEW",
      }),
    );
    return json(200, res.Attributes);
  }

  if (method === "DELETE") {
    await ddb.send(new DeleteCommand({ TableName: process.env.WORK_TASKS_TABLE, Key: { id } }));
    return json(204, {});
  }

  return json(405, { message: "Method not allowed." });
};
