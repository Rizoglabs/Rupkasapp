import { db } from './supabase';
import type { CommercialState } from './commercial';

const RKP_FORMAT = 'RKP';
const RKP_VERSION = 1;
const PBKDF2_ITERATIONS = 310_000;
const MAX_FILE_BYTES = 25 * 1024 * 1024;

type JsonRecord = Record<string, unknown>;

function bytesToBase64(bytes: Uint8Array) {
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

function base64ToBytes(value: string) {
  const binary = atob(value);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

function normalizeName(value: string) {
  return value.trim().toLocaleLowerCase('id-ID').normalize('NFKC').replace(/\s+/g, ' ');
}

function categoryKey(type: string, name: string, parentKey: string | null, used: Map<string, number>) {
  const base = `${type}:${parentKey || 'root'}:${normalizeName(name)}`;
  const n = (used.get(base) || 0) + 1;
  used.set(base, n);
  return n === 1 ? base : `${base}#${n}`;
}

async function deriveKey(password: string, salt: Uint8Array) {
  const material = await crypto.subtle.importKey('raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveKey']);
  return crypto.subtle.deriveKey(
    { name: 'PBKDF2', salt, iterations: PBKDF2_ITERATIONS, hash: 'SHA-256' },
    material,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt']
  );
}

async function encryptPayload(payload: JsonRecord, password: string) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await deriveKey(password, salt);
  const plaintext = new TextEncoder().encode(JSON.stringify(payload));
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, plaintext));
  return {
    magic: RKP_FORMAT,
    version: RKP_VERSION,
    cipher: 'AES-256-GCM',
    kdf: 'PBKDF2-SHA-256',
    iterations: PBKDF2_ITERATIONS,
    salt: bytesToBase64(salt),
    iv: bytesToBase64(iv),
    ciphertext: bytesToBase64(ciphertext),
  };
}

async function decryptEnvelope(envelope: JsonRecord, password: string): Promise<JsonRecord> {
  if (envelope.magic !== RKP_FORMAT || envelope.version !== RKP_VERSION || envelope.cipher !== 'AES-256-GCM' || envelope.kdf !== 'PBKDF2-SHA-256') {
    throw new Error('RKP_UNSUPPORTED_FORMAT');
  }
  const iterations = Number(envelope.iterations);
  if (!Number.isInteger(iterations) || iterations < 100_000 || iterations > 2_000_000) throw new Error('RKP_INVALID_KDF');
  const key = await (async () => {
    const salt = base64ToBytes(String(envelope.salt));
    const material = await crypto.subtle.importKey('raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveKey']);
    return crypto.subtle.deriveKey({ name: 'PBKDF2', salt, iterations, hash: 'SHA-256' }, material, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
  })();
  try {
    const plaintext = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: base64ToBytes(String(envelope.iv)) }, key, base64ToBytes(String(envelope.ciphertext)));
    return JSON.parse(new TextDecoder().decode(plaintext)) as JsonRecord;
  } catch {
    throw new Error('RKP_INVALID_PASSWORD_OR_CORRUPT');
  }
}

export async function createRkpBackup(space: { id: string; name: string; type: 'personal'|'family' }, state: CommercialState, password: string) {
  if (password.length < 10) throw new Error('RKP_PASSWORD_TOO_SHORT');

  const { data: profile, error: profileError } = await db.from('profiles').select('rupkas_id').eq('id', (await db.auth.getUser()).data.user?.id || '').single();
  if (profileError || !profile?.rupkas_id) throw new Error('RUPKAS_ID_NOT_AVAILABLE');

  const [
    { data: categories, error: categoryError },
    { data: transactions, error: transactionError },
    { data: debts, error: debtError },
    { data: savingsGoals, error: savingsGoalError },
    { data: savingsMovements, error: savingsMovementError },
    { data: fixedBills, error: fixedBillError },
    { data: budgets, error: budgetError },
  ] = await Promise.all([
    db.from('categories').select('id,type,parent_id,name,is_system,is_active').eq('space_id', space.id).eq('is_active', true).order('type').order('name'),
    db.from('transactions').select('type,status,amount,currency_code,category_id,transaction_date,transaction_time,source_text,note').eq('space_id', space.id).order('transaction_date'),
    db.from('debts').select('direction,party_name,original_amount,due_date,status,note').eq('space_id', space.id).order('due_date'),
    db.from('savings_goals').select('name,target_amount,target_date,status').eq('space_id', space.id).order('name'),
    db.from('savings_movements').select('goal_id,type,amount,movement_date').in('goal_id', (await db.from('savings_goals').select('id').eq('space_id', space.id)).data?.map((x:any)=>x.id) || []).order('movement_date'),
    db.from('fixed_bills').select('name,default_amount,frequency,next_due_date,reminder_days_before,status,amount_type,day_of_period,category_id').eq('space_id', space.id).order('next_due_date'),
    db.from('budgets').select('period_start,period_end,limit_amount,warning_percent,name,amount,status').eq('space_id', space.id).order('period_start'),
  ]);

  const firstError = [categoryError, transactionError, debtError, savingsGoalError, savingsMovementError, fixedBillError, budgetError].find(Boolean);
  if (firstError) throw firstError;

  const used = new Map<string, number>();
  const catIdToKey = new Map<string, string>();
  const rawCategories = categories || [];
  const portableCategories = rawCategories.map((c:any) => {
    const parentKey = c.parent_id ? catIdToKey.get(c.parent_id) || null : null;
    const key = categoryKey(c.type, c.name, parentKey, used);
    catIdToKey.set(c.id, key);
    return { key, type: c.type, name: c.name, parent_key: parentKey, is_system: !!c.is_system };
  });

  const goalIdToKey = new Map<string, string>();
  const portableGoals = (savingsGoals || []).map((g:any, index:number) => {
    const key = `goal:${normalizeName(g.name)}${index ? ':'+index : ''}`;
    goalIdToKey.set(g.id, key);
    return { key, name: g.name, target_amount: Number(g.target_amount), target_date: g.target_date, status: g.status };
  });

  const payload = {
    format: RKP_FORMAT,
    version: RKP_VERSION,
    origin: {
      master_account_id: state.account.public_account_id,
      rupkas_id: profile.rupkas_id,
      sub_rupkas_id: state.membership.sub_rupkas_id,
    },
    created_at: new Date().toISOString(),
    space: { name: space.name, type: space.type },
    data: {
      categories: portableCategories,
      transactions: (transactions || []).map((t:any, index:number) => ({
        record_key: crypto.randomUUID(),
        type: t.type,
        status: t.status,
        amount: Number(t.amount),
        currency: t.currency_code,
        category_key: catIdToKey.get(t.category_id) || null,
        date: t.transaction_date,
        time: t.transaction_time,
        source: t.source_text,
        note: t.note,
      })),
      debts: (debts || []).map((d:any) => ({
        record_key: crypto.randomUUID(),
        direction: d.direction,
        party_name: d.party_name,
        original_amount: Number(d.original_amount),
        due_date: d.due_date,
        status: d.status,
        note: d.note,
      })),
      savings_goals: portableGoals,
      savings_movements: (savingsMovements || []).map((m:any) => ({
        record_key: crypto.randomUUID(),
        goal_key: goalIdToKey.get(m.goal_id) || null,
        type: m.type,
        amount: Number(m.amount),
        date: m.movement_date,
      })),
      fixed_bills: (fixedBills || []).map((b:any) => ({
        record_key: crypto.randomUUID(),
        name: b.name,
        default_amount: b.default_amount == null ? null : Number(b.default_amount),
        frequency: b.frequency,
        next_due_date: b.next_due_date,
        reminder_days_before: b.reminder_days_before,
        status: b.status,
        amount_type: b.amount_type,
        day_of_period: b.day_of_period,
        category_key: b.category_id ? (catIdToKey.get(b.category_id) || null) : null,
      })),
      budgets: (budgets || []).map((b:any) => ({
        record_key: crypto.randomUUID(),
        period_start: b.period_start,
        period_end: b.period_end,
        limit_amount: Number(b.limit_amount),
        warning_percent: b.warning_percent == null ? null : Number(b.warning_percent),
        name: b.name,
        amount: b.amount == null ? null : Number(b.amount),
        status: b.status,
      })),
    },
  };

  const envelope = await encryptPayload(payload, password);
  const blob = new Blob([JSON.stringify(envelope)], { type: 'application/octet-stream' });
  const filename = `rupkas-${space.type}-${new Date().toISOString().slice(0,10)}.rkp`;
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = filename;
  anchor.click();
  URL.revokeObjectURL(url);
  return filename;
}

export async function restoreRkpFile(file: File, password: string, targetSpaceId: string) {
  if (file.size <= 0 || file.size > MAX_FILE_BYTES) throw new Error('RKP_FILE_TOO_LARGE');
  const text = await file.text();
  let envelope: JsonRecord;
  try { envelope = JSON.parse(text) as JsonRecord; } catch { throw new Error('RKP_INVALID_FILE'); }
  const payload = await decryptEnvelope(envelope, password);
  if (payload.format !== RKP_FORMAT || payload.version !== RKP_VERSION) throw new Error('RKP_UNSUPPORTED_FORMAT');

  const { data, error } = await db.rpc('rupkas_restore_rkp_payload', {
    p_target_space_id: targetSpaceId,
    p_payload: payload,
  });
  if (error) throw error;
  return data as Record<string, unknown>;
}
