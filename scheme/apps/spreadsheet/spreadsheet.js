// spreadsheet.js --- the grid page of spreadsheet-mode (spreadsheet.scm).
// The app server serves it beside the page ('app-directory). The page
// reads and writes its workbook through the app bridge, _compos/app.
(function(){'use strict';
// The page says which theme it wears; the script reads it.
var dark=document.documentElement.dataset.theme==='dark';
var endpoint='_compos/app',api=null,book=null,model=null,timer=null,saving=false,again=false,loading=true,chartRefreshTimer=null,chartDisposables=[],chartMounted=[],chartDrawn=[],chartFailed=[],chartReport=Promise.resolve();
var status=document.getElementById('status'),app=document.getElementById('app');
function state(kind,text){status.dataset.state=kind;status.textContent=text}
function object(value){return value&&typeof value==='object'&&!Array.isArray(value)?value:{}}
function sheetNamed(name){var sheets=book&&book.getSheets?book.getSheets():[];return sheets.find(function(sheet){return sheet.getSheetName&&sheet.getSheetName()===name})}
function chartSpecs(){var extensions=object(model&&model.extensions),compos=object(extensions.compos);return Array.isArray(compos.charts)?compos.charts:[]}
function numberValue(value){if(typeof value==='number')return Number.isFinite(value)?value:0;var number=Number(String(value==null?'':value).replace(/[^0-9eE+.-]/g,''));return Number.isFinite(number)?number:0}
function chartOption(spec,values){var rows=(Array.isArray(values)?values:[]).filter(Array.isArray),head=rows[0]||[],body=rows.slice(1),type=spec.type||'line';
var base={animation:false,title:{text:spec.title||'',left:12,top:8,textStyle:{fontSize:15}},tooltip:{trigger:type==='pie'||type==='doughnut'?'item':'axis'},legend:{top:36},grid:{left:55,right:24,top:70,bottom:42,containLabel:true}};
if(type==='pie'||type==='doughnut'){base.series=[{name:head[1]||'',type:'pie',radius:type==='doughnut'?['42%','68%']:'68%',center:['50%','57%'],data:body.map(function(row){return{name:String(row[0]==null?'':row[0]),value:numberValue(row[1])}})}];return base}
if(type==='scatter'){base.xAxis={type:'value',name:head[0]||''};base.yAxis={type:'value',name:head[1]||''};base.series=[{name:head[1]||'',type:'scatter',data:body.map(function(row){return[numberValue(row[0]),numberValue(row[1])]})}];return base}
var categories=body.map(function(row){return String(row[0]==null?'':row[0])}),series=[];for(var c=1;c<Math.max(2,head.length);c++){var item={name:head[c]||('Series '+c),type:type==='line'||type==='area'?'line':'bar',data:body.map(function(row){return numberValue(row[c])})};if(type==='area')item.areaStyle={};series.push(item)}
if(type==='bar'){base.xAxis={type:'value'};base.yAxis={type:'category',data:categories}}else{base.xAxis={type:'category',data:categories};base.yAxis={type:'value'}}base.series=series;return base}
function ComposChart(props){var ref=React.useRef(null),spec=props.data||{};React.useEffect(function(){if(!ref.current||!book)return;var chart=echarts.init(ref.current,
dark?'dark':null
);
function draw(){try{var sheet=sheetNamed(spec.sheet);if(!sheet)throw new Error('No sheet named '+spec.sheet);chart.setOption(chartOption(spec,sheet.getRange(spec.source).getDisplayValues()),true);chart.resize();markChartDrawn(spec.id)}catch(e){markChartFailed(spec.id,e.message||String(e))}}draw();addEventListener('compos:chart-data',draw);var observer=typeof ResizeObserver==='function'?new ResizeObserver(function(){chart.resize()}):null;if(observer)observer.observe(ref.current);
return function(){removeEventListener('compos:chart-data',draw);if(observer)observer.disconnect();chart.dispose()}},[spec]);return React.createElement('div',{className:'compos-chart',ref:ref})}
function chartState(){var total=chartSpecs().length;if(chartFailed.length)return'error';if(chartDrawn.length===total)return'ready';if(chartMounted.length)return'mounted';return'rendered'}
function reportCharts(){var payload=JSON.stringify({state:chartState(),mounted:chartMounted.slice(),drawn:chartDrawn.slice(),failed:chartFailed.slice()});chartReport=chartReport.then(function(){return fetch(endpoint,{method:'POST',headers:{'content-type':'application/json'},body:payload})}).catch(function(e){console.error(e)})}
function markChartDrawn(id){if(chartDrawn.indexOf(id)<0)chartDrawn.push(id);reportCharts()}
function markChartFailed(id,error){chartFailed=chartFailed.filter(function(item){return item.id!==id});chartFailed.push({id:id,error:error});state('error',error);reportCharts()}
function initialChartPosition(sheet,anchor){var range=sheet.getRange(anchor).getRange(),first=sheet.getRange(range.startRow,range.startColumn).getCellRect(),last=sheet.getRange(range.endRow,range.endColumn).getCellRect();return{startX:first.left,startY:first.top,endX:last.right,endY:last.bottom}}
function mountCharts(){chartDisposables.forEach(function(disposable){disposable.dispose()});chartDisposables=[];chartMounted=[];chartDrawn=[];chartFailed=[];var specs=chartSpecs(),wanted=specs.map(function(spec){return'compos-chart-'+spec.id}),chartType=api.Enum.DrawingType.DRAWING_CHART;(book&&book.getSheets?book.getSheets():[]).forEach(function(sheet){(sheet.getAllFloatDoms?sheet.getAllFloatDoms():[]).forEach(function(dom){if(dom.id&&dom.id.indexOf('compos-chart-')===0&&wanted.indexOf(dom.id)<0)sheet.removeFloatDom(dom.id)})});specs.forEach(function(spec){try{var sheet=sheetNamed(spec.sheet);if(!sheet){markChartFailed(spec.id,'No sheet named '+spec.sheet);return}var id='compos-chart-'+spec.id,existing=sheet.getFloatDomById&&sheet.getFloatDomById(id);if(existing&&existing.type!==chartType){sheet.removeFloatDom(id);existing=null}if(existing){sheet.updateFloatDom(id,{data:spec,type:chartType,allowTransform:true,eventPassThrough:true});chartMounted.push(spec.id);return}var disposable=sheet.addFloatDomToPosition({componentKey:'ComposChart',data:spec,type:chartType,allowTransform:true,eventPassThrough:true,initPosition:initialChartPosition(sheet,spec.anchor)},id);if(disposable){chartDisposables.push(disposable);chartMounted.push(spec.id)}else markChartFailed(spec.id,'Univer did not mount the chart')}catch(e){markChartFailed(spec.id,e.message||String(e))}});reportCharts()}
function refreshCharts(){clearTimeout(chartRefreshTimer);chartRefreshTimer=setTimeout(function(){dispatchEvent(new Event('compos:chart-data'))},120)}
function cell(value,prior){var out=prior&&typeof prior==='object'?Object.assign({},prior):{};delete out.v;delete out.f;delete out.si;delete out.t;
if(typeof value==='string'&&value.charAt(0)==='=')out.f=value;else if(typeof value==='boolean'){out.v=value?1:0;out.t=3}else out.v=value;return out}
function mergeData(oldData,data){oldData=object(oldData);var next={};Object.keys(oldData).forEach(function(r){var row={};Object.keys(object(oldData[r])).forEach(function(c){var prior=oldData[r][c]||{};var clean=Object.assign({},prior);delete clean.v;delete clean.f;delete clean.si;delete clean.t;if(Object.keys(clean).length)row[c]=clean});if(Object.keys(row).length)next[r]=row});
(Array.isArray(data)?data:[]).forEach(function(row,r){(Array.isArray(row)?row:[]).forEach(function(value,c){if(!next[r])next[r]={};next[r][c]=cell(value,(oldData&&oldData[r]&&oldData[r][c])||next[r][c])})});return next}
function snapshotOf(m){var prior=object(m.univerSnapshot);prior=JSON.parse(JSON.stringify(prior));
var oldOrder=Array.isArray(prior.sheetOrder)?prior.sheetOrder:[],oldSheets=object(prior.sheets),order=[],sheets={};
(Array.isArray(m.sheets)?m.sheets:[]).forEach(function(source,i){var id=oldOrder[i]||('compos-sheet-'+(i+1)),old=oldSheets[id]||{};order.push(id);
var rows=Array.isArray(source.data)?source.data:[],cols=rows.reduce(function(n,row){return Math.max(n,Array.isArray(row)?row.length:0)},0);
sheets[id]=Object.assign({},old,{id:id,name:source.name||('Sheet'+(i+1)),rowCount:Math.max(old.rowCount||0,100,rows.length+20),columnCount:Math.max(old.columnCount||0,20,cols+5),cellData:mergeData(old.cellData,rows)})});
if(!order.length){order=['compos-sheet-1'];sheets[order[0]]={id:order[0],name:'Sheet1',rowCount:100,columnCount:20,cellData:{}}}
return Object.assign({},prior,{id:prior.id||'compos-workbook',name:prior.name||'compos Spreadsheet',appVersion:'0.25.1',locale:'enUS',styles:object(prior.styles),sheetOrder:order,sheets:sheets})}
function compact(snapshot){var order=snapshot.sheetOrder||[],nativeSheets=object(snapshot.sheets),sheets=order.map(function(id){var sheet=nativeSheets[id]||{},cells=object(sheet.cellData),maxR=-1,maxC=-1;
Object.keys(cells).forEach(function(r){Object.keys(cells[r]||{}).forEach(function(c){var x=cells[r][c]||{};if(x.f!=null||x.v!=null){maxR=Math.max(maxR,+r);maxC=Math.max(maxC,+c)}})});
var data=[];for(var r=0;r<=maxR;r++){var row=[];for(var c=0;c<=maxC;c++){var x=cells[r]&&cells[r][c]||{};row.push(x.f!=null?x.f:(x.t===3?!!x.v:(x.v==null?'':x.v)))}while(row.length&&row[row.length-1]==='')row.pop();data.push(row)}
return {name:sheet.name||'Sheet',data:data}});var active=book&&book.getActiveSheet?book.getActiveSheet():null;var activeId=active&&active.getSheetId?active.getSheetId():order[0];
return {version:2,activeSheet:Math.max(0,order.indexOf(activeId)),sheets:sheets,univerSnapshot:snapshot,extensions:object(model&&model.extensions)}}
function schedule(){if(loading)return;clearTimeout(timer);timer=setTimeout(save,500)}
async function save(){if(!book)return;if(saving){again=true;return}saving=true;again=false;state('saving','Saving…');
try{var snapshot=await Promise.resolve(book.save());var payload=compact(snapshot);var r=await fetch(endpoint,{method:'PUT',headers:{'content-type':'application/json'},body:JSON.stringify(payload)});
var answer=await r.json();if(!r.ok)throw new Error(answer.error||('Save failed: '+r.status));state('saved','Saved')}
catch(e){state('error',e.message||String(e))}finally{saving=false;if(again)save()}}
function focusGrid(){window.focus();app.focus({preventScroll:true});if(book){var sheet=book.getActiveSheet();if(sheet&&!sheet.getActiveRange())sheet.getRange('A1').activate()}}
addEventListener('message',function(e){if(e.data&&e.data.compos==='focus-granted')focusGrid()});
async function load(){try{var r=await fetch(endpoint,{cache:'no-store'});model=await r.json();
if(!r.ok||model.error)throw new Error(model.error||('Load failed: '+r.status));
var create=UniverPresets.createUniver,core=UniverCore,preset=UniverPresetSheetsCore,drawing=UniverPresetSheetsDrawing;var made=create(Object.assign(dark?{darkMode:true}:{},{
locale:core.LocaleType.EN_US,locales:{enUS:core.mergeLocales(UniverPresetSheetsCoreEnUS,UniverPresetSheetsDrawingEnUS)},presets:[preset.UniverSheetsCorePreset({container:'app'}),drawing.UniverSheetsDrawingPreset()]}));api=made.univerAPI;api.registerComponent('ComposChart',ComposChart);var chartsMounted=false;api.addEvent(api.Event.LifeCycleChanged,function(event){if(!chartsMounted&&event.stage===api.Enum.LifecycleStages.Rendered){chartsMounted=true;mountCharts()}});
book=api.createWorkbook(snapshotOf(model));var wanted=Number.isInteger(model.activeSheet)?model.activeSheet:0,sheets=book.getSheets();if(sheets[wanted])book.setActiveSheet(sheets[wanted]);
if(dark&&api.toggleDarkMode)api.toggleDarkMode(true);
api.onCommandExecuted(function(){schedule();refreshCharts()});loading=false;state('saved','Saved');setTimeout(function(){parent.postMessage({compos:'request-focus'},'*')},80)}catch(e){state('error',e.message||String(e));console.error(e)}}
addEventListener('beforeunload',function(){if(timer){clearTimeout(timer);save()}});load();
})();
