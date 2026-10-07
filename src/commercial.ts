import { db } from './supabase';

export type CommercialState = {
  account: {
    id: string;
    public_account_id: string;
    name: string;
    status: string;
    member_limit: number;
  };
  membership: {
    role: 'OWNER' | 'MEMBER';
    sub_rupkas_id: string | null;
  };
  email: string | null;
  commercial: {
    lifecycle_status: string;
    first_activation_at: string | null;
  };
  trial: {
    status: string;
    started_at: string | null;
    expires_at: string | null;
    recovery_started_at: string | null;
    recovery_expires_at: string | null;
  };
  entitlement: {
    id: string;
    plan_code: string;
    source_type: string;
    status: string;
    starts_at: string;
    ends_at: string | null;
  } | null;
  license: {
    id: string;
    plan_code: string;
    status: string;
    lifetime: boolean;
    max_active_devices: number;
    first_activated_at: string | null;
  } | null;
  latest_order: {
    id: string;
    plan_code: string;
    product_name: string;
    amount_idr: number;
    status: string;
    payment_method: string | null;
    created_at: string;
    submitted_at: string | null;
    paid_at: string | null;
  } | null;
};

export async function getCommercialState(accountId?: string | null) {
  const { data, error } = await db.rpc('rupkas_get_commercial_state', {
    p_account_id: accountId ?? null,
  });
  if (error) throw error;
  return data as CommercialState;
}

export async function startTrial(accountId: string) {
  const { data, error } = await db.rpc('rupkas_start_trial', {
    p_account_id: accountId,
  });
  if (error) throw error;
  return data as Record<string, unknown>;
}

function getOrCreateDeviceId() {
  const key = 'rupkas.device.id.v1';
  const current = localStorage.getItem(key);
  if (current && current.length >= 16) return current;
  const next = crypto.randomUUID();
  localStorage.setItem(key, next);
  return next;
}

async function sha256Hex(input: string) {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest))
    .map((value) => value.toString(16).padStart(2, '0'))
    .join('');
}

export async function registerCurrentDevice(appVersion = 'web') {
  const state = await getCommercialState();
  const deviceId = getOrCreateDeviceId();
  const fingerprintHash = await sha256Hex(deviceId + ':' + navigator.userAgent);
  const { data, error } = await db.rpc('rupkas_register_device', {
    p_account_id: state.account.id,
    p_device_fingerprint_hash: fingerprintHash,
    p_device_label: navigator.userAgent.slice(0, 120),
    p_app_version: appVersion,
  });
  if (error) throw error;
  return data as Record<string, unknown>;
}

export async function ensureCommercialSession(appVersion = 'web') {
  let state = await getCommercialState();
  if (state.trial.status === 'NOT_STARTED' && state.membership.role === 'OWNER') {
    await startTrial(state.account.id);
    state = await getCommercialState(state.account.id);
  }
  await registerCurrentDevice(appVersion);
  return state;
}

export async function createProOrder(accountId: string, paymentMethod?: string) {
  const { data, error } = await db.rpc('rupkas_create_pro_order', {
    p_account_id: accountId,
    p_payment_method: paymentMethod ?? null,
  });
  if (error) throw error;
  return data as {
    order_id: string;
    payment_id: string;
    case_id: string;
    status: string;
    amount_idr: number;
  };
}

export async function listSupportCases() {
  const { data, error } = await db.rpc('rupkas_list_support_cases');
  if (error) throw error;
  return (data ?? []) as Array<Record<string, unknown>>;
}

export async function getSupportCase(caseId: string) {
  const { data, error } = await db.rpc('rupkas_get_support_case', {
    p_case_id: caseId,
  });
  if (error) throw error;
  return data as {
    case: Record<string, unknown>;
    messages: Array<Record<string, unknown>>;
  };
}

export async function replySupportCase(caseId: string, body: string) {
  const { data, error } = await db.rpc('rupkas_reply_support_case', {
    p_case_id: caseId,
    p_body: body,
  });
  if (error) throw error;
  return data as Record<string, unknown>;
}

export async function submitPaymentProof(orderId: string, file: File) {
  const form = new FormData();
  form.append('order_id', orderId);
  form.append('file', file);

  const { data, error } = await db.functions.invoke('rupkas-payment-proof', {
    body: form,
  });
  if (error) throw error;
  return data as Record<string, unknown>;
}
