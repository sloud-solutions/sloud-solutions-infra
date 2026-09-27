import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { json, callerAccess, callerEmail } from "./access.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

export const handler = async (event) => {
  const { role, access } = await callerAccess(event, ddb);
  if (role !== "Admin" && !access.includes("work-tracker")) {
    return json(403, { message: "No access to the Work Tracker." });
  }
  const email = callerEmail(event);
  const boardId = event.pathParameters?.boardId;
  if (!boardId) return json(400, { message: "Missing board id." });

  const board = await ddb.send(new GetCommand({ TableName: process.env.WORK_BOARDS_TABLE, Key: { id: boardId } }));
  if (!board.Item) return json(404, { message: "No such board." });
  if (role !== "Admin" && board.Item.owner !== email && !(board.Item.members ?? []).includes(email)) {
    return json(403, { message: "You're not a member of this board." });
  }

  const res = await ddb.send(
    new QueryCommand({
      TableName: process.env.WORK_TASKS_TABLE,
      IndexName: process.env.WORK_TASKS_BOARD_INDEX,
      KeyConditionExpression: "boardId = :b",
      ExpressionAttributeValues: { ":b": boardId },
    }),
  );
  return json(200, res.Items ?? []);
};
