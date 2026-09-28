import { randomUUID } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";
import { S3Client, HeadObjectCommand, GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { SESClient, SendEmailCommand } from "@aws-sdk/client-ses";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const s3 = new S3Client({});
const ses = new SESClient({});

const json = (statusCode, body) => ({ statusCode, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const RESUME_LINK_EXPIRY = 7 * 24 * 60 * 60; // 7 days, for the HR notification email

export const handler = async (event) => {
  let body;
  try {
    body = JSON.parse(event.body || "{}");
  } catch {
    return json(400, { message: "Invalid JSON body." });
  }

  const name = String(body.name || "").trim();
  const email = String(body.email || "").trim();
  const phone = String(body.phone || "").trim();
  const coverNote = String(body.coverNote || "").trim();
  const jobSlug = String(body.jobSlug || "").trim();
  const jobTitle = String(body.jobTitle || "").trim();
  const resumeKey = String(body.resumeKey || "").trim();

  if (!name || !email || !jobSlug || !jobTitle || !resumeKey) {
    return json(400, { message: "Missing required fields." });
  }
  if (!EMAIL_PATTERN.test(email)) {
    return json(400, { message: "Enter a valid email address." });
  }
  if (!resumeKey.startsWith("resumes/")) {
    return json(400, { message: "Invalid resume reference." });
  }

  try {
    await s3.send(new HeadObjectCommand({ Bucket: process.env.RESUMES_BUCKET, Key: resumeKey }));
  } catch {
    return json(400, { message: "We couldn't find your uploaded resume -- please upload it again." });
  }

  const submittedAt = new Date().toISOString();
  await ddb.send(
    new PutCommand({
      TableName: process.env.APPLICATIONS_TABLE,
      Item: { id: randomUUID(), jobSlug, jobTitle, name, email, phone, coverNote, resumeKey, submittedAt },
    }),
  );

  try {
    const resumeUrl = await getSignedUrl(s3, new GetObjectCommand({ Bucket: process.env.RESUMES_BUCKET, Key: resumeKey }), {
      expiresIn: RESUME_LINK_EXPIRY,
    });
    const lines = [
      `New application for: ${jobTitle}`,
      "",
      `Name: ${name}`,
      `Email: ${email}`,
      phone && `Phone: ${phone}`,
      "",
      coverNote && `Note:\n${coverNote}\n`,
      `Resume (link valid 7 days): ${resumeUrl}`,
    ].filter(Boolean);

    await ses.send(
      new SendEmailCommand({
        Source: process.env.NOTIFY_EMAIL,
        Destination: { ToAddresses: [process.env.NOTIFY_EMAIL] },
        ReplyToAddresses: [email],
        Message: {
          Subject: { Data: `New application: ${jobTitle}` },
          Body: { Text: { Data: lines.join("\n") } },
        },
      }),
    );
  } catch (err) {
    // The application is already saved in DynamoDB -- a notification-email
    // failure shouldn't fail the applicant's submission.
    console.error("SES notification failed", err);
  }

  return json(200, { message: "Application received." });
};
