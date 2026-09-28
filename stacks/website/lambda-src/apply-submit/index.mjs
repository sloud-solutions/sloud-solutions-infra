import { randomUUID } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";
import { S3Client, HeadObjectCommand } from "@aws-sdk/client-s3";
import { SESClient, SendEmailCommand } from "@aws-sdk/client-ses";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const s3 = new S3Client({});
const ses = new SESClient({});

const json = (statusCode, body) => ({ statusCode, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

const NAME_PATTERN = /^[A-Za-z][A-Za-z\s.'-]{1,79}$/;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const PHONE_PATTERN = /^\+?[0-9\s-]{7,16}$/;
const SEGMENTS = new Set(["CoreCraft", "GrowthLab", "TechForge"]);
const SEGMENT_COLORS = { CoreCraft: "#2563EB", GrowthLab: "#22D3EE", TechForge: "#102A43" };

const escapeHtml = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

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
  const segment = String(body.segment || "").trim();
  const resumeKey = String(body.resumeKey || "").trim();

  if (!name || !email || !phone || !jobSlug || !jobTitle || !resumeKey) {
    return json(400, { message: "Missing required fields." });
  }
  if (!NAME_PATTERN.test(name)) {
    return json(400, { message: "Enter your full name using letters only." });
  }
  if (!EMAIL_PATTERN.test(email)) {
    return json(400, { message: "Enter a valid email address." });
  }
  if (!PHONE_PATTERN.test(phone)) {
    return json(400, { message: "Enter a valid phone number." });
  }
  if (!SEGMENTS.has(segment)) {
    return json(400, { message: "Invalid job category." });
  }
  if (!resumeKey.startsWith("resumes/")) {
    return json(400, { message: "Invalid resume reference." });
  }

  try {
    await s3.send(new HeadObjectCommand({ Bucket: process.env.RESUMES_BUCKET, Key: resumeKey }));
  } catch {
    return json(400, { message: "We couldn't find your uploaded resume -- please upload it again." });
  }

  const id = randomUUID();
  const submittedAt = new Date().toISOString();
  await ddb.send(
    new PutCommand({
      TableName: process.env.APPLICATIONS_TABLE,
      Item: { id, jobSlug, jobTitle, segment, name, email, phone, coverNote, resumeKey, submittedAt },
    }),
  );

  try {
    // A short, stable link back through our own API (see apply-resume-link)
    // rather than a raw presigned URL -- those run past 1,700 characters and
    // wrap badly in mail clients.
    const resumeUrl = `${process.env.APPLY_API_BASE}/apply/resume/${id}`;
    const submittedDate = new Date(submittedAt).toLocaleString("en-IN", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Kolkata" });
    const segmentColor = SEGMENT_COLORS[segment] ?? "#2563EB";

    const textLines = [
      `New application: ${jobTitle} (${segment})`,
      "",
      `Name: ${name}`,
      `Email: ${email}`,
      `Phone: ${phone}`,
      `Submitted: ${submittedDate} IST`,
      "",
      coverNote && `Note:\n${coverNote}\n`,
      `Resume: ${resumeUrl}`,
    ].filter(Boolean);

    const row = (label, value) =>
      `<tr><td style="padding:6px 0;color:#64748B;font-size:13px;width:110px;vertical-align:top;">${label}</td><td style="padding:6px 0;color:#1F2937;font-size:14px;">${value}</td></tr>`;

    const html = `<!doctype html>
<html>
  <body style="margin:0;padding:0;background-color:#F1F5F9;font-family:Arial,Helvetica,sans-serif;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#F1F5F9;padding:32px 16px;">
      <tr>
        <td align="center">
          <table role="presentation" width="560" cellpadding="0" cellspacing="0" style="background-color:#ffffff;border-radius:12px;overflow:hidden;border:1px solid #E2E8F0;">
            <tr>
              <td style="background-color:#102A43;padding:20px 28px;">
                <span style="color:#ffffff;font-size:16px;font-weight:bold;">Sloud Solutions</span>
                <span style="float:right;color:#22D3EE;font-size:12px;font-weight:bold;letter-spacing:0.4px;">NEW APPLICATION</span>
              </td>
            </tr>
            <tr>
              <td style="padding:28px;">
                <span style="display:inline-block;background-color:${segmentColor}1A;color:${segmentColor};font-size:12px;font-weight:bold;padding:4px 10px;border-radius:999px;">${escapeHtml(segment)}</span>
                <h1 style="margin:12px 0 20px;color:#102A43;font-size:20px;">${escapeHtml(jobTitle)}</h1>
                <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                  ${row("Name", escapeHtml(name))}
                  ${row("Email", `<a href="mailto:${escapeHtml(email)}" style="color:#2563EB;text-decoration:none;">${escapeHtml(email)}</a>`)}
                  ${row("Phone", escapeHtml(phone))}
                  ${row("Submitted", `${submittedDate} IST`)}
                </table>
                ${
                  coverNote
                    ? `<div style="margin-top:18px;padding:14px 16px;background-color:#F8FAFC;border-radius:8px;color:#1F2937;font-size:14px;line-height:1.6;white-space:pre-wrap;">${escapeHtml(coverNote)}</div>`
                    : ""
                }
                <a href="${resumeUrl}" style="display:inline-block;margin-top:24px;background-color:#2563EB;color:#ffffff;font-size:14px;font-weight:bold;text-decoration:none;padding:12px 22px;border-radius:8px;">Download resume</a>
              </td>
            </tr>
            <tr>
              <td style="padding:16px 28px;background-color:#F8FAFC;border-top:1px solid #E2E8F0;">
                <span style="color:#94A3B8;font-size:12px;">Sloud Solutions Careers &middot; sloudsolutions.com</span>
              </td>
            </tr>
          </table>
        </td>
      </tr>
    </table>
  </body>
</html>`;

    await ses.send(
      new SendEmailCommand({
        Source: `Sloud Solutions Careers <${process.env.NOTIFY_EMAIL}>`,
        Destination: { ToAddresses: [process.env.NOTIFY_EMAIL] },
        ReplyToAddresses: [email],
        Message: {
          Subject: { Data: `New application: ${jobTitle} (${segment})` },
          Body: { Text: { Data: textLines.join("\n") }, Html: { Data: html } },
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
