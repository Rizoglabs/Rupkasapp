import { db } from './supabase';

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
  const closes=overlay.querySelectorAll<HTMLButtonElement>('[data-family-close]');
  closes.forEach(btn=>btn.addEventListener('click',closeModal));
  overlay.addEventListener('click',e=>{if(e.target===overlay)closeModal()});

  const save=async()=>{
    const name=input.value.trim();
    if(!name){error.textContent='Nama Family Space wajib diisi.';error.hidden=false;input.focus();return}
    if(busy)return;
    busy=true;
    submit.disabled=true;
    submit.textContent='Membuat…';
    error.hidden=true;
    const {error:rpcError}=await db.rpc('create_family_space',{p_name:name});
    if(rpcError){
      error.textContent=rpcError.message||'Gagal membuat Family Space.';
      error.hidden=false;
      busy=false;
      submit.disabled=false;
      submit.textContent='Buat Family Space';
      return;
    }
    closeModal();
    window.location.reload();
  };
  submit.addEventListener('click',()=>void save());
  input.addEventListener('keydown',e=>{if(e.key==='Enter')void save();if(e.key==='Escape')closeModal()});
  requestAnimationFrame(()=>input.focus());
}

document.addEventListener('click',e=>{
  const target=e.target as HTMLElement|null;
  const button=target?.closest<HTMLButtonElement>('.family-create button');
  if(!button)return;
  if(!button.textContent?.includes('Buat Family Space'))return;
  e.preventDefault();
  e.stopPropagation();
  openModal();
},true);
