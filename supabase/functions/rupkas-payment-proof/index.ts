import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function getKey(envName: string, fallbackName?: string): string {
  const raw = Deno.env.get(envName)?.trim();
  if (raw) {
    if (raw.startsWith("{")) {
      try {
        const parsed = JSON.parse(raw);
        const first = Object.values(parsed).find((v) => typeof v === "string" && v.length > 20);
        if (typeof first === "string") return first;
      } catch {
        // fall through
      }
    }
    return raw;
  }
  return fallbackName ? Deno.env.get(fallbackName)?.trim() || "" : "";
}

const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim() || "";
const publishableKey = getKey("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_ANON_KEY");
const secretKey = getKey("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY");
const bucket = "rupkas-payment-proofs";

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function sha256(file: File) {
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  if (!supabaseUrl || !publishableKey || !secretKey) return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500);

  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return json({ error: "AUTH_REQUIRED" }, 401);
  const token = auth.slice("Bearer ".length).trim();
  if (!token) return json({ error: "AUTH_REQUIRED" }, 401);

  const userClient = createClient(supabaseUrl, publishableKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const adminClient = createClient(supabaseUrl, secretKey);

  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) return json({ error: "INVALID_SESSION" }, 401);

  let form: FormData;
  try { form = await req.formData(); } catch { return json({ error: "INVALID_MULTIPART" }, 400); }

  const orderId = String(form.get("order_id") || "").trim();
  const file = form.get("file");
  if (!orderId) return json({ error: "ORDER_ID_REQUIRED" }, 400);
  if (!(file instanceof File)) return json({ error: "FILE_REQUIRED" }, 400);
  if (file.size <= 0 || file.size > 5 * 1024 * 1024) return json({ error: "PROOF_TOO_LARGE" }, 413);

  const allowed = new Set(["image/jpeg", "image/png", "image/webp", "application/pdf"]);
  if (!allowed.has(file.type)) return json({ error: "PROOF_MIME_NOT_ALLOWED" }, 415);

  const extension = ({
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/webp": "webp",
    "application/pdf": "pdf",
  } as Record<string, string>)[file.type];

  const storagePath = `orders/${orderId}/${crypto.randomUUID()}.${extension}`;
  const hash = await sha256(file);

  const { error: uploadError } = await adminClient.storage.from(bucket).upload(storagePath, file, {
    contentType: file.type,
    cacheControl: "3600",
    upsert: false,
  });
  if (uploadError) return json({ error: "STORAGE_UPLOAD_FAILED", detail: uploadError.message }, 502);

  const { data, error: rpcError } = await userClient.rpc("rupkas_submit_payment_proof_metadata", {
    p_order_id: orderId,
    p_storage_bucket: bucket,
    p_storage_path: storagePath,
    p_mime_type: file.type,
    p_size_bytes: file.size,
    p_sha256: hash,
  });

  if (rpcError) {
    await adminClient.storage.from(bucket).remove([storagePath]);
    return json({ error: rpcError.message || "PROOF_REGISTRATION_FAILED" }, 400);
  }

  return json(data, 200);
});
