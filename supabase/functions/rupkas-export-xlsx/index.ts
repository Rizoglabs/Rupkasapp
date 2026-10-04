import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import * as XLSX from "npm:xlsx@0.18.5";
import { createClient } from "npm:@supabase/supabase-js@2.58.0";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export default {
  async fetch(req: Request) {
    if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
    if (req.method !== "POST") return new Response(JSON.stringify({ error: "METHOD_NOT_ALLOWED" }), { status: 405, headers: { ...cors, "Content-Type": "application/json" } });

    try {
      const auth = req.headers.get("Authorization");
      if (!auth?.startsWith("Bearer ")) throw new Error("UNAUTHORIZED");

      const url = Deno.env.get("SUPABASE_URL") ?? "";
      const key = Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
      const db = createClient(url, key, { global: { headers: { Authorization: auth } } });

      const { data: userData, error: userError } = await db.auth.getUser();
      if (userError || !userData.user) throw new Error("UNAUTHORIZED");

      const body = await req.json().catch(() => ({}));
      const spaceId = String(body.space_id ?? "");
      if (!spaceId) throw new Error("SPACE_REQUIRED");

      const { data: member, error: memberError } = await db.from("space_members").select("id").eq("space_id", spaceId).eq("user_id", userData.user.id).eq("status", "active").maybeSingle();
      if (memberError || !member) throw new Error("FORBIDDEN");

      const [tx, cats, debts, savings, bills, budgets, space] = await Promise.all([
        db.from("transactions").select("id,type,amount,currency_code,category_id,transaction_date,transaction_time,source_text,note,status,version,created_at,updated_at").eq("space_id", spaceId).order("transaction_date", { ascending: true }),
        db.from("categories").select("id,name,type").eq("space_id", spaceId),
        db.from("debts").select("id,direction,party_name,original_amount,due_date,status,note,version").eq("space_id", spaceId),
        db.from("savings_goals").select("id,name,target_amount,target_date,status,created_at").eq("space_id", spaceId),
        db.from("fixed_bills").select("id,name,default_amount,frequency,next_due_date,reminder_days_before,status").eq("space_id", spaceId),
        db.from("budgets").select("period_start,period_end,limit_amount,warning_percent").eq("space_id", spaceId),
        db.from("spaces").select("id,name,type").eq("id", spaceId).maybeSingle(),
      ]);
      for (const x of [tx,cats,debts,savings,bills,budgets,space]) if (x.error) throw x.error;

      const catMap = new Map((cats.data ?? []).map((c:any) => [c.id, c.name]));
      const wb = XLSX.utils.book_new();

      const transactionRows = (tx.data ?? []).map((r:any) => ({
        Tanggal: r.transaction_date,
        Waktu: r.transaction_time ?? "",
        Tipe: r.type,
        Kategori: catMap.get(r.category_id) ?? "",
        Nominal: Number(r.amount),
        Currency: r.currency_code ?? "IDR",
        Status: r.status,
        Sumber: r.source_text ?? "",
        Catatan: r.note ?? "",
        Version: r.version,
        Dibuat: r.created_at,
        Diubah: r.updated_at,
      }));
      XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet(transactionRows), "Transactions");

      XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet((debts.data ?? []).map((r:any)=>({
        Arah:r.direction,Pihak:r.party_name,Nominal:Number(r.original_amount),Jatuh_Tempo:r.due_date??"",Status:r.status,Catatan:r.note??"",Version:r.version
      }))), "Debts");

      XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet((savings.data ?? []).map((r:any)=>({
        Nama:r.name,Target:Number(r.target_amount),Target_Date:r.target_date??"",Status:r.status,Dibuat:r.created_at
      }))), "Savings");

      XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet((bills.data ?? []).map((r:any)=>({
        Nama:r.name,Nominal:Number(r.default_amount??0),Frekuensi:r.frequency,Next_Due:r.next_due_date,Reminder_Days:r.reminder_days_before,Status:r.status
      }))), "Fixed Bills");

      XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet((budgets.data ?? []).map((r:any)=>({
        Period_Start:r.period_start,Period_End:r.period_end,Limit:Number(r.limit_amount),Warning_Percent:Number(r.warning_percent??0)
      }))), "Budgets");

      const buffer = XLSX.write(wb, { bookType: "xlsx", type: "array" });
      const file = new Uint8Array(buffer);
      const safeName = String(space.data?.name ?? "space").replace(/[^a-zA-Z0-9-_]+/g, "-").slice(0, 60) || "space";
      return new Response(file, {
        status: 200,
        headers: {
          ...cors,
          "Content-Type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          "Content-Disposition": `attachment; filename="rupkas-${safeName}.xlsx"`,
          "Cache-Control": "no-store",
        },
      });
    } catch (e) {
      const message = e instanceof Error ? e.message : "EXPORT_FAILED";
      const status = message === "UNAUTHORIZED" ? 401 : message === "FORBIDDEN" ? 403 : 400;
      return new Response(JSON.stringify({ error: message }), { status, headers: { ...cors, "Content-Type": "application/json" } });
    }
  },
};
