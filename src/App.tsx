import { FormEvent, useEffect, useMemo, useState } from 'react';
import { createClient } from '@supabase/supabase-js';
import './styles.css';

const supabase = createClient(import.meta.env.VITE_SUPABASE_URL, import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY);
const money = new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 });
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Jakarta' }).format(new Date());
const key = () => today().slice(0, 7);
const start = (m = key()) => `${m}-01`;
const end = (m = key()) => { const [y, mo] = m.split('-').map(Number); return `${y}-${String(mo).padStart(2, '0')}-${String(new Date(Date.UTC(y, mo, 0)).getUTCDate()).padStart(2, '0')}`; };

type Space = { id: string; name: string; type: 'personal' | 'family'; owner_user_id: string; status: string };
type Member = { id: string; space_id: string; user_id: string; role: 'owner' | 'member'; status: string };
type Category = { id: string; name: string; type: 'income' | 'expense' };
type Tx = { id: string; type: 'income' | 'expense'; amount: number; category_id: string; transaction_date: string; note: string | null; status: 'confirmed' | 'voided'; version: number };

function App() {
  const [session, setSession] = useState<any>(null);
  const [ready, setReady] = useState(false);
  const [guest, setGuest] = useState(false);
  const [spaces, setSpaces] = useState<Space[]>([]);
  const [space, setSpace] = useState<Space | null>(null);
  const [member, setMember] = useState<Member | null>(null);
  const [notice, setNotice] = useState('');

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session)).finally(() => setReady(true));
    const { data } = supabase.auth.onAuthStateChange((_event, next) => setSession(next));
    return () => data.subscription.unsubscribe();
  }, []);

  useEffect(() => { if (session) void loadSpaces(); else { setSpaces([]); setSpace(null); setMember(null); } }, [session]);

  async function loadSpaces() {
    setReady(false); setNotice('');
    const { data: members, error: me } = await supabase.from('space_members').select('id,space_id,user_id,role,status').eq('user_id', session.user.id).eq('status', 'active');
    if (me) { setNotice(me.message); setReady(true); return; }
    const ids = (members ?? []).map((m: any) => m.space_id);
    const { data: rows, error } = ids.length ? await supabase.from('spaces').select('id,name,type,owner_user_id,status').in('id', ids).eq('status', 'active').order('name') : { data: [], error: null };
    if (error) { setNotice(error.message); setReady(true); return; }
    const list = (rows ?? []) as Space[];
    const saved = localStorage.getItem('rupkas.space');
    const active = list.find((x) => x.id === saved) ?? list[0] ?? null;
    setSpaces(list); setSpace(active); setMember(((members ?? []).find((m: any) => m.space_id === active?.id) ?? null) as Member | null); setReady(true);
  }

  if (!ready) return <div className="center"><div className="spinner" />Memuat Rupkas…</div>;
  if (!session && !guest) return <Auth notice={notice} setNotice={setNotice} onGuest={() => setGuest(true)} />;
  if (guest) return <Guest onBack={() => setGuest(false)} />;
  if (!space) return <Onboarding notice={notice} setNotice={setNotice} refresh={loadSpaces} />;

  return <DashboardShell session={session} spaces={spaces} space={space} member={member} setNotice={setNotice} notice={notice} refresh={loadSpaces} />;
}

function Auth({ notice, setNotice, onGuest }: { notice: string; setNotice: (x: string) => void; onGuest: () => void }) {
  const [signup, setSignup] = useState(false); const [email, setEmail] = useState(''); const [password, setPassword] = useState(''); const [name, setName] = useState(''); const [busy, setBusy] = useState(false);
  async function submit(e: FormEvent) {
    e.preventDefault(); setBusy(true); setNotice('');
    try {
      if (signup) { const { data, error } = await supabase.auth.signUp({ email: email.trim(), password, options: { data: { display_name: name.trim() } } }); if (error) throw error; if (!data.session) setNotice('Akun dibuat. Cek email untuk verifikasi.'); }
      else { const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password }); if (error) throw error; }
    } catch (e: any) { setNotice(e.message ?? 'Autentikasi gagal.'); } finally { setBusy(false); }
  }
  return <main className="auth"><section className="panel auth-panel"><div className="logo">R</div><p className="eyebrow">RUPKAS</p><h1>Rupiah Kas, lebih jelas.</h1><p className="muted">Catat, monitor, dan bagikan keuangan keluarga.</p><div className="seg"><button className={!signup ? 'active' : ''} onClick={() => setSignup(false)}>Masuk</button><button className={signup ? 'active' : ''} onClick={() => setSignup(true)}>Daftar</button></div><form onSubmit={submit}>{signup && <label>Nama<input value={name} onChange={(e) => setName(e.target.value)} required /></label>}<label>Email<input type="email" value={email} onChange={(e) => setEmail(e.target.value)} required /></label><label>Password<input type="password" value={password} onChange={(e) => setPassword(e.target.value)} minLength={8} required /></label>{notice && <div className="notice">{notice}</div>}<button className="primary" disabled={busy}>{busy ? 'Memproses…' : signup ? 'Buat akun' : 'Masuk'}</button></form><button className="link" onClick={onGuest}>Coba guest/local mode</button></section></main>;
}

function Onboarding({ notice, setNotice, refresh }: { notice: string; setNotice: (x: string) => void; refresh: () => Promise<void> }) {
  const [name, setName] = useState(''); const [code, setCode] = useState(''); const [mode, setMode] = useState<'family' | 'join'>('family'); const [busy, setBusy] = useState(false);
  async function run() { setBusy(true); setNotice(''); try { const fn = mode === 'family' ? 'create_family_space' : 'claim_invitation'; const args = mode === 'family' ? { p_name: name.trim() } : { p_code: code.trim() }; const { error } = await supabase.rpc(fn, args); if (error) throw error; await refresh(); } catch (e: any) { setNotice(e.message ?? 'Tidak dapat melanjutkan.'); } finally { setBusy(false); } }
  return <main className="auth"><section className="panel auth-panel"><div className="logo">R</div><p className="eyebrow">ONBOARDING</p><h1>Ruang Anda belum aktif.</h1><p className="muted">Pastikan email sudah diverifikasi. Personal Space akan diprovision oleh backend; Anda juga bisa membuat atau bergabung ke Family Space.</p><div className="seg"><button className={mode === 'family' ? 'active' : ''} onClick={() => setMode('family')}>Buat keluarga</button><button className={mode === 'join' ? 'active' : ''} onClick={() => setMode('join')}>Gabung</button></div>{mode === 'family' ? <label>Nama Family Space<input value={name} onChange={(e) => setName(e.target.value)} placeholder="Keluarga Gy" /></label> : <label>Kode undangan<input value={code} onChange={(e) => setCode(e.target.value)} placeholder="Kode invitation" /></label>}{notice && <div className="notice">{notice}</div>}<button className="primary" disabled={busy || (mode === 'family' ? !name.trim() : !code.trim())} onClick={() => void run()}>{busy ? 'Memproses…' : mode === 'family' ? 'Buat Family Space' : 'Gabung'}</button><button className="ghost wide" onClick={() => void refresh()}>Periksa ulang</button></section></main>;
}

function DashboardShell({ session, spaces, space, member, setNotice, notice, refresh }: { session: any; spaces: Space[]; space: Space; member: Member | null; setNotice: (x: string) => void; notice: string; refresh: () => Promise<void> }) {
  const [view, setView] = useState<'summary' | 'transactions' | 'budget' | 'family' | 'settings'>('summary');
  function changeSpace(id: string) { localStorage.setItem('rupkas.space', id); location.reload(); }
  const nav = [['summary', 'Ringkasan'], ['transactions', 'Transaksi'], ['budget', 'Budget'], ['family', 'Keluarga'], ['settings', 'Lainnya']] as const;
  return <div className="app"><header className="top"><div><div className="brand">Rupkas</div><span className="eyebrow">{space.type === 'family' ? 'FAMILY SPACE' : 'PERSONAL SPACE'}</span></div><div className="top-actions"><select value={space.id} onChange={(e) => changeSpace(e.target.value)}>{spaces.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select><button className="ghost" onClick={() => void supabase.auth.signOut()}>Keluar</button></div></header><main className="main">{notice && <div className="notice dismiss">{notice}<button onClick={() => setNotice('')}>×</button></div>}{view === 'summary' && <Summary space={space} setView={setView} refresh={refresh} />}{view === 'transactions' && <Transactions space={space} notice={setNotice} />}{view === 'budget' && <Budget space={space} notice={setNotice} />}{view === 'family' && <Family space={space} member={member} notice={setNotice} />}{view === 'settings' && <Settings session={session} space={space} />}</main><nav className="nav">{nav.map(([id, label]) => <button key={id} className={view === id ? 'active' : ''} onClick={() => setView(id)}>{label}</button>)}</nav></div>;
}

function Summary({ space, setView, refresh }: { space: Space; setView: (v: any) => void; refresh: () => Promise<void> }) {
  const [month, setMonth] = useState(key()); const [summary, setSummary] = useState<any>(null); const [rows, setRows] = useState<Tx[]>([]); const [cats, setCats] = useState<Category[]>([]);
  const label = useMemo(() => new Intl.DateTimeFormat('id-ID', { month: 'long', year: 'numeric' }).format(new Date(`${month}-01`)), [month]);
  async function load() { const [s, t, c] = await Promise.all([supabase.rpc('get_month_summary', { p_space_id: space.id, p_month_start: start(month) }), supabase.from('transactions').select('id,type,amount,category_id,transaction_date,note,status,version').eq('space_id', space.id).gte('transaction_date', start(month)).lte('transaction_date', end(month)).order('transaction_date', { ascending: false }).limit(8), supabase.from('categories').select('id,name,type').eq('space_id', space.id).eq('is_active', true)]); if (!s.error) setSummary(Array.isArray(s.data) ? s.data[0] : s.data); if (!t.error) setRows((t.data ?? []) as Tx[]); if (!c.error) setCats((c.data ?? []) as Category[]); }
  useEffect(() => { void load(); }, [space.id, month]);
  return <><div className="month"><button className="ghost" onClick={() => setMonth(addMonth(month, -1))}>‹</button><strong>{label}</strong><button className="ghost" onClick={() => setMonth(addMonth(month, 1))}>›</button></div><div className="stats"><Stat l="Pemasukan" v={money.format(Number(summary?.income_total ?? 0))} c="positive"/><Stat l="Pengeluaran" v={money.format(Number(summary?.expense_total ?? 0))} c="negative"/><Stat l="Arus kas" v={money.format(Number(summary?.net_cashflow ?? 0))}/><Stat l="Budget" v={`${Number(summary?.budget_utilization ?? 0).toFixed(1)}%`}/></div><div className="two"><QuickAdd space={space} saved={async () => { await load(); await refresh(); }} notice={() => {}}/><section className="panel"><div className="panel-head"><div><span className="eyebrow">TERBARU</span><h2>Transaksi</h2></div><button className="linkish" onClick={() => setView('transactions')}>Lihat semua</button></div>{rows.length ? rows.map((r) => <TxRow key={r.id} row={r} cat={cats.find((c) => c.id === r.category_id)?.name}/>) : <div className="empty">Belum ada transaksi.</div>}</section></div><section className="panel budget-summary"><span className="eyebrow">BUDGET</span><h2>{money.format(Number(summary?.budget_actual ?? 0))} / {money.format(Number(summary?.budget_limit ?? 0))}</h2><div className="meter"><div style={{ width: `${Math.min(100, Number(summary?.budget_utilization ?? 0))}%` }}/></div></section></>;
}

function QuickAdd({ space, saved, notice }: { space: Space; saved: () => Promise<void>; notice: (x: string) => void }) {
  const [type, setType] = useState<'expense' | 'income'>('expense'); const [cats, setCats] = useState<Category[]>([]); const [cat, setCat] = useState(''); const [amount, setAmount] = useState(''); const [note, setNote] = useState(''); const [busy, setBusy] = useState(false);
  useEffect(() => { supabase.from('categories').select('id,name,type').eq('space_id', space.id).eq('type', type).eq('is_active', true).order('name').then(({ data, error }) => { if (error) notice(error.message); else { setCats((data ?? []) as Category[]); setCat(data?.[0]?.id ?? ''); } }); }, [space.id, type]);
  async function add() { const n = Number(amount.replace(/[^0-9]/g, '')); if (n <= 0 || !cat) return; setBusy(true); try { const { error } = await supabase.rpc('create_transaction', { p_space_id: space.id, p_type: type, p_amount: n, p_category_id: cat, p_transaction_date: today(), p_transaction_time: new Date().toTimeString().slice(0, 8), p_note: note.trim() || null, p_client_operation_id: crypto.randomUUID() }); if (error) throw error; setAmount(''); setNote(''); await saved(); } catch (e: any) { notice(e.message ?? 'Gagal menyimpan transaksi.'); } finally { setBusy(false); } }
  return <section className="panel"><span className="eyebrow">QUICK ADD</span><h2>Catat transaksi</h2><div className="seg"><button className={type === 'expense' ? 'active' : ''} onClick={() => setType('expense')}>Pengeluaran</button><button className={type === 'income' ? 'active' : ''} onClick={() => setType('income')}>Pemasukan</button></div><input inputMode="numeric" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="Nominal Rp"/><select value={cat} onChange={(e) => setCat(e.target.value)}>{cats.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select><input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Catatan (opsional)"/><button className="primary wide" disabled={busy || !cat || !amount} onClick={() => void add()}>{busy ? 'Menyimpan…' : 'Simpan'}</button></section>;
}

function Transactions({ space, notice }: { space: Space; notice: (x: string) => void }) {
  const [month, setMonth] = useState(key()); const [rows, setRows] = useState<Tx[]>([]); const [cats, setCats] = useState<Category[]>([]); const [filter, setFilter] = useState<'all' | 'income' | 'expense'>('all');
  async function load() { const [t, c] = await Promise.all([supabase.from('transactions').select('id,type,amount,category_id,transaction_date,note,status,version').eq('space_id', space.id).gte('transaction_date', start(month)).lte('transaction_date', end(month)).order('transaction_date', { ascending: false }).order('created_at', { ascending: false }).limit(200), supabase.from('categories').select('id,name,type').eq('space_id', space.id)]); if (t.error) notice(t.error.message); else setRows((t.data ?? []) as Tx[]); if (!c.error) setCats((c.data ?? []) as Category[]); }
  useEffect(() => { void load(); }, [space.id, month]);
  async function voidRow(row: Tx) { const reason = window.prompt('Alasan void transaksi', 'Koreksi'); if (reason === null) return; const { error } = await supabase.rpc('void_transaction', { p_transaction_id: row.id, p_expected_version: row.version, p_reason: reason.trim() }); if (error) notice(error.message); else await load(); }
  const rows2 = filter === 'all' ? rows : rows.filter((r) => r.type === filter);
  return <section className="panel"><div className="panel-head"><div><span className="eyebrow">HISTORI</span><h2>Transaksi</h2></div></div><div className="toolbar"><button className="ghost" onClick={() => setFilter('all')}>Semua</button><button className="ghost" onClick={() => setFilter('expense')}>Pengeluaran</button><button className="ghost" onClick={() => setFilter('income')}>Pemasukan</button><span className="grow"/><button className="ghost" onClick={() => setMonth(addMonth(month, -1))}>‹</button><strong>{month}</strong><button className="ghost" onClick={() => setMonth(addMonth(month, 1))}>›</button></div>{rows2.length ? rows2.map((r) => <div className="tx" key={r.id}><div><strong>{cats.find((c) => c.id === r.category_id)?.name ?? 'Kategori'}</strong><span>{r.transaction_date} · {r.note ?? (r.type === 'expense' ? 'Pengeluaran' : 'Pemasukan')} {r.status === 'voided' ? '· VOID' : ''}</span></div><div className="tx-right"><strong className={r.type === 'expense' ? 'negative' : 'positive'}>{r.type === 'expense' ? '-' : '+'}{money.format(Number(r.amount))}</strong>{r.status !== 'voided' && <button className="linkish danger" onClick={() => void voidRow(r)}>Void</button>}</div></div>) : <div className="empty">Tidak ada transaksi.</div>}</section>;
}

function Budget({ space, notice }: { space: Space; notice: (x: string) => void }) {
  const m = key(); const [value, setValue] = useState(''); const [saved, setSaved] = useState<any>(null);
  useEffect(() => { supabase.from('budgets').select('*').eq('space_id', space.id).eq('period_start', start(m)).maybeSingle().then(({ data }) => { setSaved(data); if (data) setValue(String(data.limit_amount)); }); }, [space.id]);
  async function save() { const n = Number(value.replace(/[^0-9]/g, '')); const { data, error } = await supabase.rpc('upsert_budget', { p_space_id: space.id, p_period_start: start(m), p_period_end: end(m), p_limit: n, p_warning_percent: 80 }); if (error) notice(error.message); else setSaved(data); }
  return <section className="panel narrow"><span className="eyebrow">BUDGET</span><h2>{new Intl.DateTimeFormat('id-ID', { month: 'long', year: 'numeric' }).format(new Date(`${m}-01`))}</h2><label>Batas pengeluaran<input inputMode="numeric" value={value} onChange={(e) => setValue(e.target.value)} placeholder="5000000"/></label><button className="primary wide" disabled={!value} onClick={() => void save()}>Simpan budget</button>{saved && <div className="success">Budget aktif: <strong>{money.format(Number(saved.limit_amount))}</strong></div>}</section>;
}

function Family({ space, member, notice }: { space: Space; member: Member | null; notice: (x: string) => void }) {
  const [members, setMembers] = useState<Member[]>([]); const [code, setCode] = useState(''); const [busy, setBusy] = useState(false);
  async function load() { const { data, error } = await supabase.from('space_members').select('id,space_id,user_id,role,status').eq('space_id', space.id).eq('status', 'active').order('role'); if (error) notice(error.message); else setMembers((data ?? []) as Member[]); }
  useEffect(() => { void load(); }, [space.id]);
  async function invite() { setBusy(true); const { data, error } = await supabase.rpc('create_invitation', { p_space_id: space.id, p_ttl_hours: 168 }); if (error) notice(error.message); else setCode(String(data)); setBusy(false); }
  return <section className="two"><section className="panel"><span className="eyebrow">FAMILY SPACE</span><h2>Anggota</h2>{members.map((m) => <div className="row" key={m.id}><div><strong>{m.role === 'owner' ? 'Owner' : 'Member'}</strong><span>{m.user_id.slice(0, 8)}…</span></div><span className="pill">{m.status}</span></div>)}</section><section className="panel"><span className="eyebrow">INVITATION</span><h2>Undang anggota</h2>{member?.role === 'owner' ? <><button className="primary wide" disabled={busy} onClick={() => void invite()}>{busy ? 'Membuat…' : 'Buat kode'}</button>{code && <div className="code">{code}</div>}<p className="muted small">Berlaku 7 hari dan hanya untuk claim membership.</p></> : <p className="muted">Hanya Owner yang dapat membuat invitation.</p>}</section></section>;
}

function Settings({ session, space }: { session: any; space: Space }) { return <section className="two"><section className="panel"><span className="eyebrow">AKUN</span><h2>{session.user.email}</h2><p className="muted">Supabase Auth · email/password · email verification</p></section><section className="panel"><span className="eyebrow">SPACE</span><h2>{space.name}</h2><p className="muted">{space.type === 'family' ? 'Family Space' : 'Personal Space'} · IDR · Asia/Jakarta</p></section></section>; }

function Guest({ onBack }: { onBack: () => void }) {
  const [rows, setRows] = useState<any[]>([]); const [amount, setAmount] = useState(''); const [note, setNote] = useState('');
  useEffect(() => { setRows(JSON.parse(localStorage.getItem('rupkas.guest') ?? '[]')); }, []);
  function add() { const n = Number(amount.replace(/[^0-9]/g, '')); if (!n) return; const next = [{ id: crypto.randomUUID(), amount: n, note, date: today() }, ...rows]; setRows(next); localStorage.setItem('rupkas.guest', JSON.stringify(next)); setAmount(''); setNote(''); }
  return <main className="auth"><section className="panel guest-panel"><div className="panel-head"><div><span className="eyebrow">GUEST MODE</span><h1>Catat tanpa akun.</h1></div><button className="ghost" onClick={onBack}>Kembali</button></div><p className="muted">Data hanya disimpan di browser ini.</p><div className="two"><input inputMode="numeric" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="Nominal Rp"/><input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Catatan"/></div><button className="primary wide" onClick={add}>Simpan lokal</button>{rows.map((r) => <div className="tx" key={r.id}><div><strong>Pengeluaran</strong><span>{r.date} · {r.note || 'Tanpa catatan'}</span></div><strong className="negative">-{money.format(r.amount)}</strong></div>)}</section></main>;
}

function Stat({ l, v, c = '' }: { l: string; v: string; c?: string }) { return <div className="stat"><span>{l}</span><strong className={c}>{v}</strong></div>; }
function TxRow({ row, cat }: { row: Tx; cat?: string }) { return <div className="tx"><div><strong>{cat ?? 'Kategori'}</strong><span>{row.transaction_date} · {row.note ?? (row.type === 'expense' ? 'Pengeluaran' : 'Pemasukan')}</span></div><strong className={row.type === 'expense' ? 'negative' : 'positive'}>{row.type === 'expense' ? '-' : '+'}{money.format(Number(row.amount))}</strong></div>; }
function addMonth(m: string, delta: number) { const [y, mo] = m.split('-').map(Number); const d = new Date(Date.UTC(y, mo - 1 + delta, 1)); return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`; }

export default App;
