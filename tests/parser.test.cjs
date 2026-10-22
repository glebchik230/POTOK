const assert=require('node:assert/strict');
const P=require('../parser.js');
for(const [input,expected] of [['1 234,56',123456],['1,234.56',123456],['1.234,56',123456],['0',0],['',null],['oops',null],[-5,-500]])assert.equal(P.money(input),expected);
assert.equal(P.date('46246'),'2026-08-12');assert.equal(P.date('31.02.2026'),'');
let rows=[['Дата операции','Списание','Зачисление','Назначение платежа','Контрагент','Номер документа'],['12.08.2026',120,'','Закупка','ООО Поставщик','1'],['13.08.2026','',500,'Эквайринг','Банк','2']];
let h=P.detect(rows),parsed=P.parseRows(rows,h.index,h.map,'test');assert.equal(parsed.tx.length,2);assert.equal(parsed.tx.reduce((s,t)=>s+t.amount,0),38000);assert.equal(parsed.tx[1].category,'Выручка');assert.equal(P.classify('Перевод собственных средств в фонд Налоги',-100),'Собственные переводы');
let txt='1CClientBankExchange\nРасчСчет=123\nНачальныйОстаток=50.00\nСекцияДокумент=Платежное поручение\nДата=12.08.2026\nНомер=1\nПлательщикСчет=123\nПолучательСчет=456\nПолучатель=Поставщик\nСумма=20.00\nНазначениеПлатежа=Оплата\nКонецДокумента';let one=P.parse1C(txt);assert.equal(one.tx[0].amount,-2000);assert.equal(one.meta.opening,5000);
assert.notEqual(P.key({...parsed.tx[0],document:'2'}),P.key(parsed.tx[0]));console.log('Parser tests passed');
