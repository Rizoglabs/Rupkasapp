import "jsr:@supabase/functions-js@2/edge-runtime.d.ts";

Deno.serve(async () => new Response(
  JSON.stringify({ error: "ENDPOINT_UNAVAILABLE" }),
  { status: 410, headers: { "Content-Type": "application/json" } }
));
