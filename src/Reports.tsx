import { useEffect, useMemo, useState } from 'react';
import { db } from './supabase';
import './styles.css';

const money = new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 });
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Jakarta' }).format(new Date());

type Space = { id: string; name: string; type: 'personal' | 'family'; owner_user_id: string; status: string };
type Period = 'month' | '3m' | '6m' | '12m';
type Tx = { id: string; type: 'income' | 'expense'; amount: number; category_id: string; transaction_date: string; transaction_time: string | null; note: string | null; status: 'confirmed' | 'voided' };
type Cat = { id: string; name: string; type: 'income' | 'expense' };
type Debt = { id: string; direction: 'receivable' | 'payable'; party_name: string; original_amount: number; due_date: string | null; status: string; note: string | null };

function Icon({name}:{name:string}){return <span className="material-symbols-rounded" aria-hidden="true">{name}</span>}
function isoDate(d:Date){return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0')}
function monthKey(date:string){return date.slice(0,7)}
function monthLabel(key:string){return new Intl.DateTimeFormat('id-ID',{month:'short',year:'numeric'}).format(new Date(key+'-01T12:00:00'))}
function csvCell(value:unknown){return '"' + String(value??'').replaceAll('"','""') + '"'}
function downloadCsv(name:string,rows:Array<Array<unknown>>){const csv=rows.map(row=>row.map(csvCell).join(',')).join('\n');const blob=new Blob(['\ufeff'+csv],{type:'text/csv;charset=utf-8'});const url=URL.createObjectURL(blob);const a=document.createElement('a');a.href=url;a.download=name;a.click();URL.revokeObjectURL(url)}

export default function Reports({space,notice}:{space:Space,notice:(message:string)=>void}){
  const [period,setPeriod]=useState<Period>('month');
  const [transactions,setTransactions]=useState<Tx[]>([]);
  const [categories,setCategories]=useState<Cat[]>([]);
  const [debts,setDebts]=useState<Debt[]>([]);
  const [payments,setPayments]=useState<Array<{debt_id:string;amount:number}>>([]);
  const [busy,setBusy]=useState(true);
  const [exporting,setExporting]=useState(false);

  const range=useMemo(()=>{
    const end=new Date(today()+'T12:00:00');
    const monthsBack=period==='month'?0:period==='3m'?2:period==='6m'?5:11;
    const start=new Date(end.getFullYear(),end.getMonth()-monthsBack,1);
    return {start:isoDate(start),end:today()};
  },[period]);

  async function load(){
    setBusy(true);
    const [tx,cat,debt]=await Promise.all([
      db.from('transactions').select('id,type,amount,category_id,transaction_date,transaction_time,note,status').eq('space_id',space.id).eq('status','confirmed').gte('transaction_date',range.start).lte('transaction_date',range.end).order('transaction_date',{ascending:true}).order('transaction_time',{ascending:true}).limit(5000),
      db.from('categories').select('id,name,type').eq('space_id',space.id).eq('is_active',true),
      db.from('debts').select('id,direction,party_name,original_amount,due_date,status,note').eq('space_id',space.id).order('due_date',{ascending:true})
    ]);
    if(tx.error)notice(tx.error.message);
    if(cat.error)notice(cat.error.message);
    if(debt.error)notice(debt.error.message);
    const txRows=(tx.data??[]) as Tx[];
    const debtRows=(debt.data??[]) as Debt[];
    setTransactions(txRows);setCategories((cat.data??[]) as Cat[]);setDebts(debtRows);
    if(debtRows.length){
      const p=await db.from('debt_payments').select('debt_id,amount').in('debt_id',debtRows.map(d=>d.id));
      if(p.error)notice(p.error.message);
      setPayments((p.data??[]) as Array<{debt_id:string;amount:number}>);
    }else setPayments([]);
    setBusy(false);
  }
  useEffect(()=>{void load()},[space.id,range.start,range.end]);

  const catMap=useMemo(()=>new Map(categories.map(c=>[c.id,c.name])),[categories]);
  const totals=useMemo(()=>transactions.reduce((a,r)=>{if(r.type==='income')a.income+=Number(r.amount);else a.expense+=Number(r.amount);return a},{income:0,expense:0}),[transactions]);
  const net=totals.income-totals.expense;

  const categoryRows=useMemo(()=>{
    const map=new Map<string,number>();
    for(const r of transactions)if(r.type==='expense')map.set(r.category_id,(map.get(r.category_id)??0)+Number(r.amount));
    return [...map.entries()].map(([categoryId,amount])=>({categoryId,name:catMap.get(categoryId)??'Kategori',amount,percent:totals.expense?amount/totals.expense*100:0})).sort((a,b)=>b.amount-a.amount);
  },[transactions,catMap,totals.expense]);

  const trendRows=useMemo(()=>{
    const map=new Map<string,{income:number;expense:number}>();
    for(const r of transactions){const key=monthKey(r.transaction_date);const v=map.get(key)??{income:0,expense:0};if(r.type==='income')v.income+=Number(r.amount);else v.expense+=Number(r.amount);map.set(key,v)}
    const start=new Date(range.start+'T12:00:00');const end=new Date(range.end+'T12:00:00');const rows:Array<{key:string;income:number;expense:number;net:number}>=[];let cursor=new Date(start.getFullYear(),start.getMonth(),1);
    while(cursor<=end){const key=cursor.getFullYear()+'-'+String(cursor.getMonth()+1).padStart(2,'0');const v=map.get(key)??{income:0,expense:0};rows.push({key,income:v.income,expense:v.expense,net:v.income-v.expense});cursor.setMonth(cursor.getMonth()+1,1)}
    return rows;
  },[transactions,range.start,range.end]);

  const debtRows=useMemo(()=>{
    const paidMap=new Map<string,number>();
    for(const p of payments)paidMap.set(p.debt_id,(paidMap.get(p.debt_id)??0)+Number(p.amount));
    const now=today();
    return debts.map(d=>{const paid=paidMap.get(d.id)??0;const remaining=Math.max(Number(d.original_amount)-paid,0);return {...d,paid,remaining,overdue:remaining>0&&!!d.due_date&&d.due_date<now}});
  },[debts,payments]);

  const debtSummary=useMemo(()=>({
    payable:debtRows.filter(d=>d.direction==='payable').reduce((s,d)=>s+d.remaining,0),
    receivable:debtRows.filter(d=>d.direction==='receivable').reduce((s,d)=>s+d.remaining,0),
    overdue:debtRows.filter(d=>d.overdue).reduce((s,d)=>s+d.remaining,0)
  }),[debtRows]);

  const maxTrend=Math.max(1,...trendRows.flatMap(r=>[r.income,r.expense]));
  const maxCategory=Math.max(1,...categoryRows.map(r=>r.amount));

  async function exportXlsx(){
    setExporting(true);
    try{
      const {data,error}=await db.functions.invoke('rupkas-export-xlsx',{body:{space_id:space.id}});
      if(error)throw error;
      const blob=data instanceof Blob?data:new Blob([data],{type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'});
      const url=URL.createObjectURL(blob);const a=document.createElement('a');a.href=url;a.download='rupkas-'+(space.name.replace(/[^a-zA-Z0-9-_]+/g,'-').slice(0,60)||'space')+'.xlsx';a.click();URL.revokeObjectURL(url);
    }catch(e:any){notice(e?.message||'Export XLSX gagal')}finally{setExporting(false)}
  }

  function exportCsv(){
    const rows:Array<Array<unknown>>=[
      ['RUPKAS REPORT',space.name],['Periode',range.start,range.end],[],
      ['RINGKASAN'],['Pemasukan',totals.income],['Pengeluaran',totals.expense],['Net cashflow',net],[],
      ['KATEGORI PENGELUARAN'],['Kategori','Nominal','Persentase'],...categoryRows.map(r=>[r.name,r.amount,r.percent.toFixed(2)+'%']),[],
      ['TREND'],['Bulan','Pemasukan','Pengeluaran','Net cashflow'],...trendRows.map(r=>[monthLabel(r.key),r.income,r.expense,r.net]),[],
      ['HUTANG / PIUTANG'],['Arah','Pihak','Nominal Awal','Terbayar','Sisa','Jatuh Tempo','Overdue'],...debtRows.map(d=>[d.direction==='payable'?'Utang':'Piutang',d.party_name,d.original_amount,d.paid,d.remaining,d.due_date??'',d.overdue?'Ya':'Tidak']),[],
      ['TRANSAKSI'],['Tanggal','Waktu','Tipe','Kategori','Nominal','Catatan'],...transactions.map(r=>[r.transaction_date,r.transaction_time??'',r.type==='income'?'Pemasukan':'Pengeluaran',catMap.get(r.category_id)??'Kategori',r.amount,r.note??''])
    ];
    downloadCsv('rupkas-report-'+range.start+'-'+range.end+'.csv',rows);
  }

  return <section className="reports-page">
    <div className="reports-head">
      <div><span className="eyebrow">LAPORAN</span><h1>Keuangan lebih mudah dibaca.</h1><p>Ringkasan arus kas, kategori pengeluaran, tren, dan kewajiban untuk {space.name}.</p></div>
      <div className="reports-actions no-print"><button className="ghost" onClick={()=>window.print()}><Icon name="print"/>Print</button><button className="ghost" onClick={exportCsv}><Icon name="download"/>CSV</button><button className="primary" disabled={exporting} onClick={()=>void exportXlsx()}><Icon name="table_view"/>{exporting?'Menyiapkan…':'XLSX'}</button></div>
    </div>
    <div className="report-period no-print">{([['month','1 Bulan'],['3m','3 Bulan'],['6m','6 Bulan'],['12m','12 Bulan']] as Array<[Period,string]>).map(([id,label])=><button key={id} className={period===id?'active':''} onClick={()=>setPeriod(id)}>{label}</button>)}</div>
    <div className="report-stat-grid">
      <div className="report-stat"><span>Pemasukan</span><strong className="positive">{money.format(totals.income)}</strong></div>
      <div className="report-stat"><span>Pengeluaran</span><strong className="negative">{money.format(totals.expense)}</strong></div>
      <div className="report-stat"><span>Net cashflow</span><strong className={net>=0?'positive':'negative'}>{net>=0?'+':''}{money.format(net)}</strong></div>
      <div className="report-stat"><span>Transaksi</span><strong>{transactions.length}</strong></div>
    </div>
    {busy?<div className="home-empty">Memuat laporan…</div>:<div className="reports-grid">
      <section className="report-card report-wide"><div className="report-card-head"><div><span className="eyebrow">CASHFLOW</span><h2>Pemasukan vs pengeluaran</h2></div><Icon name="monitoring"/></div><div className="cashflow-bars">
        <div><span>Pemasukan</span><strong>{money.format(totals.income)}</strong><div className="cash-bar"><i style={{width:Math.max(2,totals.income/Math.max(1,totals.income,totals.expense)*100)+'%'}}/></div></div>
        <div><span>Pengeluaran</span><strong>{money.format(totals.expense)}</strong><div className="cash-bar expense"><i style={{width:Math.max(2,totals.expense/Math.max(1,totals.income,totals.expense)*100)+'%'}}/></div></div>
      </div></section>
      <section className="report-card"><div className="report-card-head"><div><span className="eyebrow">CATEGORY</span><h2>Pengeluaran per kategori</h2></div><Icon name="pie_chart"/></div>
        {categoryRows.length?<div className="report-category-list">{categoryRows.slice(0,8).map(row=><div key={row.categoryId} className="report-category-row"><div className="report-row-top"><strong>{row.name}</strong><span>{row.percent.toFixed(1)}%</span></div><div className="category-bar"><i style={{width:Math.max(2,row.amount/maxCategory*100)+'%'}}/></div><div className="report-row-bottom"><span>{money.format(row.amount)}</span></div></div>)}</div>:<div className="home-empty">Belum ada pengeluaran pada periode ini.</div>}
      </section>
      <section className="report-card"><div className="report-card-head"><div><span className="eyebrow">TREND</span><h2>Trend bulanan</h2></div><Icon name="show_chart"/></div>
        {trendRows.length?<div className="trend-list">{trendRows.map(row=><div className="trend-row" key={row.key}><div className="trend-label"><strong>{monthLabel(row.key)}</strong><span>{money.format(row.net)}</span></div><div className="trend-track"><i className="trend-income" style={{width:Math.max(2,row.income/maxTrend*100)+'%'}}/><i className="trend-expense" style={{width:Math.max(2,row.expense/maxTrend*100)+'%'}}/></div><div className="trend-legend"><span>Pemasukan {money.format(row.income)}</span><span>Pengeluaran {money.format(row.expense)}</span></div></div>)}</div>:<div className="home-empty">Belum ada data tren.</div>}
      </section>
      <section className="report-card report-wide"><div className="report-card-head"><div><span className="eyebrow">DEBT</span><h2>Hutang & piutang</h2></div><Icon name="account_balance_wallet"/></div>
        <div className="report-debt-summary"><div><span>Total utang</span><strong className="negative">{money.format(debtSummary.payable)}</strong></div><div><span>Total piutang</span><strong className="positive">{money.format(debtSummary.receivable)}</strong></div><div><span>Overdue</span><strong className={debtSummary.overdue?'negative':''}>{money.format(debtSummary.overdue)}</strong></div></div>
        {debtRows.length?<div className="report-debt-list">{debtRows.slice(0,8).map(d=><div className="report-debt-row" key={d.id}><div><strong>{d.party_name}</strong><span>{d.direction==='payable'?'Utang':'Piutang'} · sisa {money.format(d.remaining)}{d.due_date?' · '+d.due_date:''}</span></div><span className={d.remaining===0?'report-badge':d.overdue?'report-badge overdue':'report-badge'}>{d.remaining===0?'Lunas':d.overdue?'Overdue':'Open'}</span></div>)}</div>:<div className="home-empty">Belum ada hutang/piutang.</div>}
      </section>
      <section className="report-card report-wide"><div className="report-card-head"><div><span className="eyebrow">TRANSACTIONS</span><h2>Transaksi dalam laporan</h2></div><Icon name="receipt_long"/></div>
        {transactions.length?<div className="report-table-wrap"><table className="report-table"><thead><tr><th>Tanggal</th><th>Tipe</th><th>Kategori</th><th>Nominal</th><th>Catatan</th></tr></thead><tbody>{transactions.slice(-50).reverse().map(r=><tr key={r.id}><td>{r.transaction_date}</td><td>{r.type==='income'?'Pemasukan':'Pengeluaran'}</td><td>{catMap.get(r.category_id)??'Kategori'}</td><td className={r.type==='income'?'positive':'negative'}>{r.type==='income'?'+':'-'}{money.format(Number(r.amount))}</td><td>{r.note||'—'}</td></tr>)}</tbody></table></div>:<div className="home-empty">Belum ada transaksi.</div>}
      </section>
    </div>}
  </section>
}
