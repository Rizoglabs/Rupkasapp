const DB_NAME='rupkas-offline-v1';
const STORE='tx_queue';

export type PendingOp={
  id:string;
  kind:'create'|'update';
  space_id:string;
  transaction_id?:string;
  base_version?:number;
  type:'income'|'expense';
  amount:number;
  category_id:string;
  transaction_date:string;
  transaction_time:string|null;
  note:string|null;
  client_operation_id:string;
  created_at:number;
  attempts:number;
  state:'pending'|'conflict';
  conflict_payload?:any;
};

function openDb():Promise<IDBDatabase>{
  return new Promise((resolve,reject)=>{
    const req=indexedDB.open(DB_NAME,2);
    req.onupgradeneeded=()=>{
      const d=req.result;
      let s=d.objectStoreNames.contains(STORE)?req.transaction!.objectStore(STORE):d.createObjectStore(STORE,{keyPath:'id'});
      if(!s.indexNames.contains('space_id'))s.createIndex('space_id','space_id');
      if(!s.indexNames.contains('client_operation_id'))s.createIndex('client_operation_id','client_operation_id',{unique:true});
      if(!s.indexNames.contains('state'))s.createIndex('state','state');
    };
    req.onsuccess=()=>resolve(req.result);
    req.onerror=()=>reject(req.error);
  });
}

async function put(row:PendingOp){
  const d=await openDb();
  await new Promise<void>((resolve,reject)=>{
    const tx=d.transaction(STORE,'readwrite');
    tx.objectStore(STORE).put(row);
    tx.oncomplete=()=>resolve();
    tx.onerror=()=>reject(tx.error);
  });
}

export async function enqueueTransaction(x:{
  space_id:string;type:'income'|'expense';amount:number;category_id:string;
  transaction_date:string;transaction_time:string;note:string|null;client_operation_id:string;
}){
  await put({ ...x,id:crypto.randomUUID(),kind:'create',created_at:Date.now(),attempts:0,state:'pending' });
}

export async function enqueueTransactionUpdate(x:{
  space_id:string;transaction_id:string;base_version:number;type:'income'|'expense';amount:number;category_id:string;
  transaction_date:string;transaction_time:string|null;note:string|null;client_operation_id:string;
}){
  await put({ ...x,id:crypto.randomUUID(),kind:'update',created_at:Date.now(),attempts:0,state:'pending' });
}

async function allRows(spaceId?:string){
  const d=await openDb();
  return await new Promise<PendingOp[]>((resolve,reject)=>{
    const tx=d.transaction(STORE,'readonly');
    const s=tx.objectStore(STORE);
    const req=spaceId?s.index('space_id').getAll(spaceId):s.getAll();
    req.onsuccess=()=>resolve((req.result as PendingOp[]).filter(x=>x.state==='pending'));
    req.onerror=()=>reject(req.error);
  });
}

export async function pendingCount(spaceId?:string){
  return (await allRows(spaceId)).length;
}

async function remove(id:string){
  const d=await openDb();
  await new Promise<void>((resolve,reject)=>{
    const tx=d.transaction(STORE,'readwrite');
    tx.objectStore(STORE).delete(id);
    tx.oncomplete=()=>resolve();
    tx.onerror=()=>reject(tx.error);
  });
}

async function updateRow(id:string,patch:Partial<PendingOp>){
  const d=await openDb();
  await new Promise<void>((resolve,reject)=>{
    const tx=d.transaction(STORE,'readwrite');
    const s=tx.objectStore(STORE);
    const r=s.get(id);
    r.onsuccess=()=>{if(r.result)s.put({...r.result,...patch})};
    tx.oncomplete=()=>resolve();
    tx.onerror=()=>reject(tx.error);
  });
}

export async function flushTransactionQueue(client:any,spaceId?:string){
  if(!navigator.onLine)return{sent:0,failed:0,conflicts:0,pending:await pendingCount(spaceId)};
  const list=await allRows(spaceId);
  let sent=0,failed=0,conflicts=0;
  for(const x of list){
    if(x.kind==='create'){
      const {error}=await client.rpc('create_transaction',{
        p_space_id:x.space_id,p_type:x.type,p_amount:x.amount,p_category_id:x.category_id,
        p_transaction_date:x.transaction_date,p_transaction_time:x.transaction_time,
        p_source_text:null,p_note:x.note,p_client_operation_id:x.client_operation_id
      });
      if(error){failed++;await updateRow(x.id,{attempts:x.attempts+1});continue}
      sent++;await remove(x.id);
      continue;
    }

    const {data,error}=await client.rpc('sync_transaction_update',{
      p_operation_id:x.client_operation_id,p_transaction_id:x.transaction_id,p_base_version:x.base_version,
      p_type:x.type,p_amount:x.amount,p_category_id:x.category_id,p_transaction_date:x.transaction_date,
      p_transaction_time:x.transaction_time,p_note:x.note
    });
    if(error){failed++;await updateRow(x.id,{attempts:x.attempts+1});continue}
    if(data?.status==='conflict'){
      conflicts++;
      await updateRow(x.id,{state:'conflict',conflict_payload:data});
      continue;
    }
    sent++;await remove(x.id);
  }
  return{sent,failed,conflicts,pending:await pendingCount(spaceId)};
}
