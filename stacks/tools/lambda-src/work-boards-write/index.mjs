import { randomUUID } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  PutCommand,
  GetCommand,
  UpdateCommand,
  DeleteCommand,
  QueryCommand,
  BatchWriteCommand,
} from "@aws-sdk/lib-dynamodb";
import { json, callerAccess, callerEmail } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

const canManage = (board, role) => role === "Admin";

async function tasksForBoard(boardId) {
  const res = await ddb.send(
    new QueryCommand({
      TableName: process.env.WORK_TASKS_TABLE,
      IndexName: process.env.WORK_TASKS_BOARD_INDEX,
      KeyConditionExpression: "boardId = :b",
      ExpressionAttributeValues: { ":b": boardId },
    }),
  );
  return res.Items ?? [];
}

/** Deletes every task on a board before the board itself goes, so nothing orphans. */
async function deleteBoardTasks(boardId) {
  const items = await tasksForBoard(boardId);
  for (let i = 0; i < items.length; i += 25) {
    const batch = items.slice(i, i + 25);
    await ddb.send(
      new BatchWriteCommand({
        RequestItems: { [process.env.WORK_TASKS_TABLE]: batch.map((t) => ({ DeleteRequest: { Key: { id: t.id } } })) },
      }),
    );
  }
}

/** Someone dropped from a board's membership loses any tasks assigned to them -- back to Unassigned. */
async function unassignRemovedMembers(boardId, removedEmails) {
  if (!removedEmails.length) return;
  const items = await tasksForBoard(boardId);
  const now = new Date().toISOString();
  for (const t of items.filter((t) => removedEmails.includes(t.assignee))) {
    await ddb.send(
      new UpdateCommand({
        TableName: process.env.WORK_TASKS_TABLE,
        Key: { id: t.id },
        UpdateExpression: "SET #assignee = :empty, #updatedAt = :now",
        ExpressionAttributeNames: { "#assignee": "assignee", "#updatedAt": "updatedAt" },
        ExpressionAttributeValues: { ":empty": "", ":now": now },
      }),
    );
  }
}

export const handler = async (event) => {
  const { role, access } = await callerAccess(event, ddb);
  if (role !== "Admin" && !access.includes("work-tracker")) {
    return json(403, { message: "No access to the Work Tracker." });
  }
  const email = callerEmail(event);
  const method = event.requestContext.http.method;

  if (method === "POST") {
    if (role !== "Admin") {
      return json(403, { message: "Only an Admin can create a board." });
    }
    let body;
    try {
      body = JSON.parse(event.body || "{}");
    } catch {
      return json(400, { message: "Invalid JSON body." });
    }
    if (!body.name || !String(body.name).trim()) return json(400, { message: "Board name is required." });

    const item = {
      id: randomUUID(),
      name: String(body.name).trim(),
      description: String(body.description ?? "").trim(),
      team: String(body.team ?? "").trim(),
      owner: email ?? "unknown",
      members: Array.isArray(body.members) ? body.members.map(String) : [],
      createdAt: new Date().toISOString(),
    };
    await ddb.send(new PutCommand({ TableName: process.env.WORK_BOARDS_TABLE, Item: item }));
    return json(201, item);
  }

  const id = event.pathParameters?.id;
  if (!id) return json(400, { message: "Missing id." });
  const existing = await ddb.send(new GetCommand({ TableName: process.env.WORK_BOARDS_TABLE, Key: { id } }));
  if (!existing.Item) return json(404, { message: "No such board." });
  if (!canManage(existing.Item, role)) {
    return json(403, { message: "Only an Admin can change this board." });
  }

  if (method === "PATCH") {
    let body;
    try {
      body = JSON.parse(event.body || "{}");
    } catch {
      return json(400, { message: "Invalid JSON body." });
    }

    const names = {};
    const values = {};
    const sets = [];
    if (body.name !== undefined) {
      if (!String(body.name).trim()) return json(400, { message: "Board name is required." });
      names["#name"] = "name";
      values[":name"] = String(body.name).trim();
      sets.push("#name = :name");
    }
    if (body.description !== undefined) {
      names["#description"] = "description";
      values[":description"] = String(body.description).trim();
      sets.push("#description = :description");
    }
    if (body.team !== undefined) {
      names["#team"] = "team";
      values[":team"] = String(body.team).trim();
      sets.push("#team = :team");
    }
    let removedMembers = [];
    if (body.members !== undefined) {
      const newMembers = Array.isArray(body.members) ? body.members.map(String) : [];
      const oldMembers = existing.Item.members ?? [];
      removedMembers = oldMembers.filter((m) => !newMembers.includes(m));
      names["#members"] = "members";
      values[":members"] = newMembers;
      sets.push("#members = :members");
    }
    if (!sets.length) return json(400, { message: "Nothing to update." });

    const res = await ddb.send(
      new UpdateCommand({
        TableName: process.env.WORK_BOARDS_TABLE,
        Key: { id },
        UpdateExpression: `SET ${sets.join(", ")}`,
        ExpressionAttributeNames: names,
        ExpressionAttributeValues: values,
        ReturnValues: "ALL_NEW",
      }),
    );
    await unassignRemovedMembers(id, removedMembers);
    return json(200, res.Attributes);
  }

  if (method === "DELETE") {
    await deleteBoardTasks(id);
    await ddb.send(new DeleteCommand({ TableName: process.env.WORK_BOARDS_TABLE, Key: { id } }));
    return json(204, {});
  }

  return json(405, { message: "Method not allowed." });
};
