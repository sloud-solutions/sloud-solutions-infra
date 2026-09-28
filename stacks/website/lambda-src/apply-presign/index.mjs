import { randomUUID } from "node:crypto";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

const s3 = new S3Client({});

// Public endpoint (no login -- job applicants don't have an account), so
// keep the surface area small: fixed size cap, fixed allow-list, no other
// inputs trusted from the caller besides those two.
const MAX_BYTES = 5 * 1024 * 1024; // 5 MB
const ALLOWED_TYPES = {
  "application/pdf": "pdf",
  "application/msword": "doc",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
};

const json = (statusCode, body) => ({ statusCode, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

export const handler = async (event) => {
  let body;
  try {
    body = JSON.parse(event.body || "{}");
  } catch {
    return json(400, { message: "Invalid JSON body." });
  }

  const contentType = body.contentType;
  const sizeBytes = Number(body.sizeBytes);
  const ext = ALLOWED_TYPES[contentType];
  if (!ext) return json(400, { message: "Only PDF, DOC, or DOCX resumes are accepted." });
  if (!Number.isFinite(sizeBytes) || sizeBytes <= 0) return json(400, { message: "Missing file size." });
  if (sizeBytes > MAX_BYTES) return json(400, { message: `File is too large -- the limit is ${MAX_BYTES / (1024 * 1024)} MB.` });

  const resumeKey = `resumes/${randomUUID()}.${ext}`;
  const uploadUrl = await getSignedUrl(
    s3,
    new PutObjectCommand({ Bucket: process.env.RESUMES_BUCKET, Key: resumeKey, ContentType: contentType, ContentLength: sizeBytes }),
    { expiresIn: 300 },
  );

  return json(200, { uploadUrl, resumeKey });
};
