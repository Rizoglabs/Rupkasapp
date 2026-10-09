import { useEffect, useRef, useState } from 'react';
import { createRkpBackup, restoreRkpFile } from './rkp';
import { getCommercialState, type CommercialState } from './commercial';

export default function RkpPanel({space,state,notice}:{space:{id:string,name:string,type:'personal'|'family'},state:CommercialState|null,notice:(message:string)=>void}){
  const [password,setPassword]=useState(''),[restoreFile,setRestoreFile]=useState<File|null>(null),[busy,setBusy]=useState(false);
  const fileRef=useRef<HTMLInputElement|null>(null);
  async function backup(){
    if(!state){notice('Status akun belum siap.');return}
    if(password.length<10){notice('Gunakan password backup minimal 10 karakter.');return}
    setBusy(true);
    try{const filename=await createRkpBackup(space,state,password);notice(`Backup ${filename} berhasil dibuat.`);setPassword('')}
    catch(e:any){notice(e?.message||'Gagal membuat backup .rkp')}
    finally{setBusy(false)}
  }
  async function restore(){
    if(!restoreFile){notice('Pilih file .rkp terlebih dahulu.');return}
    if(password.length<10){notice('Masukkan password backup minimal 10 karakter.');return}
    setBusy(true);
    try{
      const result=await restoreRkpFile(restoreFile,password,space.id);
      notice(`Restore selesai: ${JSON.stringify(result.counts||{})}`);
      setRestoreFile(null);setPassword('');if(fileRef.current)fileRef.current.value='';
    }catch(e:any){notice(e?.message||'Gagal restore .rkp')}
    finally{setBusy(false)}
  }
  return <section className="panel rkp-panel"><div className="panel-head"><div><span className="eyebrow">RUPKAS ENCRYPTED BACKUP</span><h2>Backup & Restore</h2><p className="small muted">{state?.account.name || space.name}{state?.email ? ' · ' + state.email : ''}</p></div><span className="material-symbols-rounded" aria-hidden="true">shield_lock</span></div><p className="muted">Format <strong>.rkp</strong> terenkripsi AES-256-GCM. Backup tidak berisi ID database internal, entitlement, license, atau secret developer.</p><label>Password backup<input type="password" autoComplete="new-password" value={password} onChange={e=>setPassword(e.target.value)} placeholder="Minimal 10 karakter"/></label><button className="primary wide" disabled={busy||!state||password.length<10} onClick={()=>void backup()}><span className="material-symbols-rounded" aria-hidden="true">encrypted</span>Buat Backup .rkp</button><div className="rkp-divider"/><label>Pilih file .rkp<input ref={fileRef} type="file" accept=".rkp,application/octet-stream" onChange={e=>setRestoreFile(e.target.files?.[0]||null)}/></label><button className="ghost wide" disabled={busy||!state||!restoreFile||password.length<10} onClick={()=>void restore()}><span className="material-symbols-rounded" aria-hidden="true">restore</span>Restore ke Space ini</button><p className="small muted">Restore hanya diterima bila Master Account ID dan Rupkas ID di dalam backup cocok dengan akun aktif. Space tujuan wajib kosong.</p></section>}
