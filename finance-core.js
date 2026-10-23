(function(root){
'use strict';
const CASH='__potok_cash__';
function state(d){return {cashEnabled:false,cashOpening:null,cashEntries:[],crm:{},...(d.finance||{})};}
function bankName(s){let n=String(s||'Банк').trim();if(/сбер/i.test(n))return 'Сбер';if(/альфа/i.test(n))return 'Альфа-Банк';if(/точка/i.test(n))return 'Точка';return n||'Банк';}
function effective(d){let f=state(d);if(!f.cashEnabled)return {...d};let entries=f.cashEntries||[],opening=f.cashOpening,start=opening?.date||entries.map(e=>e.date).sort()[0]||'1900-01-01';return {...d,imports:[...d.imports,{id:CASH,account:CASH,bank:'Наличные',start,end:'9999-12-31',opening:opening?.amount??null}],transactions:[...d.transactions,...entries.map(e=>({...e,id:'cash:'+e.id,key:'cash:'+e.id,account:CASH,importId:CASH,party:'Наличная касса',category:e.kind==='income'?'Выручка':e.kind==='expense'?'Прочие наличные расходы':'Собственные переводы',description:e.description||'',document:'',cashId:e.id}))]};}
function external(d,tx){let f=state(d);if(!f.cashEnabled)return tx;let cashIds=new Set(tx.filter(t=>t.cashId).map(t=>t.cashId)),ids=new Set(tx.map(t=>t.id)),linked=new Set();for(let e of f.cashEntries)if(e.bankTransactionId&&cashIds.has(e.id)&&ids.has(e.bankTransactionId)){linked.add('cash:'+e.id);linked.add(e.bankTransactionId);}return tx.filter(t=>!linked.has(t.id));}
function cashBalance(d,until){let f=state(d),o=f.cashOpening;if(!o||o.date>until)return null;return o.amount+f.cashEntries.filter(e=>e.date>=o.date&&e.date<=until).reduce((s,e)=>s+e.amount,0);}
const api={CASH,state,effective,external,cashBalance,bankName};if(typeof module!=='undefined')module.exports=api;else root.PotokFinance=api;
})(typeof window==='undefined'?globalThis:window);
