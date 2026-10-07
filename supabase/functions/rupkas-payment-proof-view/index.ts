import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim() || "";
const secretKey = Deno.env.get("SUPABASE_SECRET_KEYS")?.trim() || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() || "";

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  if (!supabaseUrl || !secretKey) return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500);

  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return json({ error: "AUTH_REQUIRED" }, 401);
  const token = auth.slice("Bearer ".length).trim();

  const adminClient = createClient(supabaseUrl, secretKey);
  const userClient = createClient(supabaseUrl, secretKey, { global: { headers: { Authorization: `Bearer ${token}` } } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return json({ error: "INVALID_SESSION" }, 401);

  const userId = userData.user.id;
  const { data: adminRow } = await adminClient.schema("private").from("developer_admins")
    .select("user_id").eq("user_id", userId).eq("is_active", true).maybeSingle();
  if (!adminRow) return json({ error: "DEVELOPER_ADMIN_REQUIRED" }, 403);

  let body: { order_id?: string };
  try { body = await req.json(); } catch { return json({ error: "INVALID_JSON" }, 400); }
  const orderId = String(body.order_id || "").trim();
  if (!orderId) return json({ error: "ORDER_ID_REQUIRED" }, 400);

  const { data: payment } = await adminClient.schema("private").from("rupkas_payments")
    .select("id").eq("order_id", orderId).order("attempt_no", { ascending: false }).limit(1).maybeSingle();
  if (!payment) return json({ error: "PAYMENT_NOT_FOUND" }, 404);

  const { data: proof } = await adminClient.schema("private").from("rupkas_payment_proofs")
    .select("id,storage_bucket,storage_path,mime_type,size_bytes,status,uploaded_at,expires_at")
    .eq("payment_id", payment.id).eq("status", "ACTIVE").order("uploaded_at", { ascending: false }).limit(1).maybeSingle();

  if (!proof) return json({ error: "PAYMENT_PROOF_NOT_FOUND" }, 404);
  if (new Date(proof.expires_at).getTime() <= Date.now()) return json({ error: "PAYMENT_PROOF_EXPIRED" }, 410);

  const { data: signed, error: signError } = await adminClient.storage
    .from(proof.storage_bucket || "rupkas-payment-proofs")
    .createSignedUrl(proof.storage_path, 300);

  if (signError || !signed?.signedUrl) return json({ error: "SIGNED_URL_FAILED" }, 502);

  const { data: order } = await adminClient.schema("private").from("rupkas_orders")
    .select("account_id").eq("id", orderId).maybeSingle();

  await adminClient.schema("private").from("rupkas_audit_events").insert({
    account_id: order?.account_id || null,
    actor_type: "DEVELOPER",
    actor_user_id: userId,
    event_type: "PAYMENT_PROOF_VIEWED",
    entity_type: "ORDER",
    entity_id: orderId,
    metadata: { proof_id: proof.id, expires_in_seconds: 300 },
  });

  return json({
    order_id: orderId,
    proof_id: proof.id,
    mime_type: proof.mime_type,
    size_bytes: proof.size_bytes,
    uploaded_at: proof.uploaded_at,
    expires_at: proof.expires_at,
    signed_url: signed.signedUrl,
    signed_url_expires_in: 300,
  });
});
