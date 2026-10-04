import { db } from './supabase';

const style=document.createElement('style');
style.textContent=`
.rupkas-family-modal-overlay{position:fixed;inset:0;z-index:9999;display:grid;place-items:center;padding:18px;background:rgba(12,25,19,.42);backdrop-filter:blur(6px)}
.rupkas-family-modal{width:min(500px,100%);padding:22px;border:1px solid rgba(20,70,48,.14);border-radius:22px;background:#fff;box-shadow:0 28px 80px rgba(8,35,23,.24);font-family:inherit}
.rupkas-family-modal-head{display:flex;align-items:flex-start;justify-content:space-between;gap:16px}
.rupkas-family-eyebrow{display:block;margin-bottom:7px;color:#537466;font-size:10px;font-weight:900;letter-spacing:.12em}
.rupkas-family-modal h2{margin:0;font-size:24px;letter-spacing:-.035em;color:#153b2c}
.rupkas-family-modal p{margin:7px 0 0;color:#6c8178;font-size:12px;line-height:1.55}
.rupkas-family-close{width:38px;height:38px;border:0;border-radius:12px;background:#f2f6f3;color:#557167;font-size:24px;cursor:pointer}
.rupkas-family-label{display:grid;gap:7px;margin-top:20px;color:#45665a;font-size:11px;font-weight:850}
.rupkas-family-label input{width:100%;box-sizing:border-box;min-height:48px;padding:10px 13px;border:1px solid #d8e3dd;border-radius:13px;background:#fff;color:#17392c;font:inherit;font-size:14px;outline:none}
.rupkas-family-label input:focus{border-color:#6eb28f;box-shadow:0 0 0 3px rgba(77,150,111,.12)}
.rupkas-family-error{margin-top:10px;padding:10px 12px;border-radius:12px;background:#fff0ef;color:#a23b35;font-size:11px;font-weight:750}
.rupkas-family-actions{display:flex;justify-content:flex-end;gap:9px;margin-top:18px}
.rupkas-family-actions button{min-height:44px;padding:9px 14px;border-radius:12px;font:inherit;font-size:12px;font-weight:850;cursor:pointer}
.rupkas-family-secondary{border:1px solid #d8e3dd;background:#fff;color:#5d746b}
.rupkas-family-primary{border:1px solid #153f2e;background:#153f2e;color:#fff}
.rupkas-family-primary:disabled{opacity:.55;cursor:wait}
@media(max-width:520px){.rupkas-family-modal{padding:18px;border-radius:18px}.rupkas-family-actions{display:grid;grid-template-columns:1fr 1fr}.rupkas-family-actions button{width:100%}}
`;
document.head.appendChild(style);

let overlay: HTMLDivElement | null = null;
let busy = false;

function closeModal(){
  overlay?.remove();
  overlay=null;
  busy=false;
}

function openModal(){
  if(overlay)return;
  overlay=document.createElement('div');
  overlay.className='rupkas-family-modal-overlay';
  overlay.innerHTML=`
    <div class="rupkas-family-modal" role="dialog" aria-modal="true" aria-labelledby="rupkas-family-modal-title">
      <div class="rupkas-family-modal-head">
        <div>
          <span class="rupkas-family-eyebrow">FAMILY SPACE</span>
          <h2 id="rupkas-family-modal-title">Buat ruang keluarga</h2>
          <p>Masukkan nama Family Space. Kamu akan menjadi Owner dan bisa mengundang anggota keluarga.</p>
        </div>
        <button type="button" class="rupkas-family-close" data-family-close aria-label="Tutup">×</button>
      </div>
      <label class="rupkas-family-label">Nama Family Space
        <input data-family-name type="text" maxlength="120" placeholder="Contoh: Keluarga Gy" autocomplete="organization" />
      </label>
      <div data-family-error class="rupkas-family-error" hidden></div>
      <div class="rupkas-family-actions">
        <button type="button" class="rupkas-family-secondary" data-family-close>Batal</button>
        <button type="button" class="rupkas-family-primary" data-family-submit>Buat Family Space</button>
      </div>
    </div>`;
  document.body.appendChild(overlay);

  const input=overlay.querySelector<HTMLInputElement>('[data-family-name]')!;
  const error=overlay.querySelector<HTMLDivElement>('[data-family-error]')!;
  const submit=overlay.querySelector<HTMLButtonElement>('[data-family-submit]')!;
  overlay.querySelectorAll<HTMLButtonElement>('[data-family-close]').forEach(btn=>btn.addEventListener('click',closeModal));
  overlay.addEventListener('click',e=>{if(e.target===overlay)closeModal()});

  const save=async()=>{
    const name=input.value.trim();
    if(!name){error.textContent='Nama Family Space wajib diisi.';error.hidden=false;input.focus();return}
    if(busy)return;
    busy=true;submit.disabled=true;submit.textContent='Membuat…';error.hidden=true;
    const {error:rpcError}=await db.rpc('create_family_space',{p_name:name});
    if(rpcError){error.textContent=rpcError.message||'Gagal membuat Family Space.';error.hidden=false;busy=false;submit.disabled=false;submit.textContent='Buat Family Space';return}
    closeModal();window.location.reload();
  };
  submit.addEventListener('click',()=>void save());
  input.addEventListener('keydown',e=>{if(e.key==='Enter')void save();if(e.key==='Escape')closeModal()});
  requestAnimationFrame(()=>input.focus());
}

document.addEventListener('click',e=>{
  const target=e.target as HTMLElement|null;
  const button=target?.closest<HTMLButtonElement>('.family-create button');
  if(!button||!button.textContent?.includes('Buat Family Space'))return;
  e.preventDefault();e.stopPropagation();openModal();
},true);
