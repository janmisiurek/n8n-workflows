'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const cfgFile = path.join(root, '.runtime', 'bindings.json');
const cfg = fs.existsSync(cfgFile) ? JSON.parse(fs.readFileSync(cfgFile, 'utf8')) : {};
const sf = cfg.salesforceBase || 'https://your-my-domain.example.com';
const base = cfg.n8nBase || 'http://localhost:5678';
const core = fs.readFileSync(path.join(root, 'src/core.js'), 'utf8');
const ids = { prepare:'EMFOfferPrepare1', decision:'EMFOfferDecide01', error:'EMFOfferError001' };
function node(name, type, parameters, x, y, extra={}) {
  return {id:crypto.createHash('sha256').update(name).digest('hex').slice(0,24),name,type,typeVersion:1,position:[x,y],parameters,...extra};
}
function code(name, js, x,y) {return node(name,'n8n-nodes-base.code',{jsCode:core+'\n'+js},x,y,{typeVersion:2});}
function webhook(name,method,p,x,y) {
  return node(name,'n8n-nodes-base.webhook',{httpMethod:method,path:p,authentication:'basicAuth',responseMode:'responseNode',options:{}},x,y,{typeVersion:2,webhookId:crypto.createHash('sha256').update(name).digest('hex').slice(0,32),...(cfg.webhookCredential?{credentials:{httpBasicAuth:cfg.webhookCredential}}:{})});
}
function http(name,endpoint,body,x,y,method='POST',extra={}) {
  return node(name,'n8n-nodes-base.httpRequest',{method,url:sf+'/services/apexrest/emfire-offers/v1/'+endpoint,authentication:'genericCredentialType',genericAuthType:'oAuth2Api',...(method==='POST'?{sendBody:true,specifyBody:'json',jsonBody:body}:{}),options:{timeout:30000}},x,y,{typeVersion:4.2,retryOnFail:true,maxTries:3,waitBetweenTries:2000,...(cfg.salesforceCredential?{credentials:{oAuth2Api:cfg.salesforceCredential}}:{}),...extra});
}
function response(name,x,y) {return node(name,'n8n-nodes-base.respondToWebhook',{respondWith:'text',responseBody:'={{ $json.html }}',options:{responseCode:'={{ $json.httpStatus || 200 }}',responseHeaders:{entries:[{name:'Content-Type',value:'text/html; charset=utf-8'},{name:'Cache-Control',value:'no-store'}]}}},x,y,{typeVersion:1.4});}
function iff(name,field,x,y) { return node(name,'n8n-nodes-base.if',{conditions:{options:{caseSensitive:true,leftValue:'',typeValidation:'strict',version:2},conditions:[{id:name,leftValue:'={{ $json.'+field+' }}',rightValue:true,operator:{type:'boolean',operation:'true',singleValue:true}}],combinator:'and'},options:{}},x,y,{typeVersion:2.2}); }
function workflow(id,name,nodes,links,settings={}) {
  const connections={};
  for(const [a,b,out=0,input=0] of links) {
    connections[a] ||= {main:[]}; connections[a].main[out] ||= []; connections[a].main[out].push({node:b,type:'main',index:input});
  }
  return {id,name,active:false,nodes,connections,settings:{executionOrder:'v1',timezone:'Europe/Warsaw',saveDataErrorExecution:'all',saveDataSuccessExecution:'all',executionTimeout:180,errorWorkflow:ids.error,...settings},pinData:{},tags:[]};
}
const render = `const result=$input.first().json; return [{json:{...result,html:renderResult(result,${JSON.stringify(base)})}}];`;
const renderPreparation = render.replace('...result,html:', "...result,respondToBrowser:$('Receive preparation').isExecuted,html:");
const prepNodes=[
  webhook('Open offer form','GET','emfire/offers',0,-300),
  http('Load demo opportunities','catalog',null,250,-300,'GET'),
  code('Render form',`const id=Date.now().toString(36)+'_'+Math.random().toString(36).slice(2,14); return [{json:{html:entryForm(${JSON.stringify(base)},id,$json.opportunities || [])}}];`,500,-300),
  response('Return form',750,-300),
  webhook('Receive preparation','POST','emfire/offers',0,0),
  node('Receive revision internally','n8n-nodes-base.executeWorkflowTrigger',{inputSource:'passthrough'},0,220,{typeVersion:1.1}),
  code('Validate request',`const input=$json.body || $json; try { const request=normalize(input); if(!['prepare','retry'].includes(request.action)) throw new Error('Niedozwolona operacja'); return [{json:{...request,valid:true,executionId:String($execution.id)}}]; } catch(e) { return [{json:{valid:false,httpStatus:400,code:e.code||'INVALID_INPUT',message:e.message}}]; }`,260,0),
  iff('Input valid?','valid',500,0),
  http('Claim and load Salesforce context','prepare','={{ JSON.stringify($json) }}',750,0),
  iff('Generate proposal?','generate',1000,0),
  code('Build model request',`return [{json:{context:$json,modelBody:modelRequest($json,${JSON.stringify(cfg.openaiModel||'gpt-4.1-mini')})}}];`,1250,0),
  node('Ask OpenAI','n8n-nodes-base.httpRequest',{method:'POST',url:'https://api.openai.com/v1/responses',authentication:'predefinedCredentialType',nodeCredentialType:'openAiApi',sendBody:true,specifyBody:'json',jsonBody:'={{ JSON.stringify($json.modelBody) }}',options:{timeout:45000}},1500,0,{typeVersion:4.2,retryOnFail:false,onError:'continueErrorOutput',...(cfg.openaiCredential?{credentials:{openAiApi:cfg.openaiCredential}}:{})}),
  code('Validate AI and calculate price',`try { const context=$('Build model request').first().json.context; const proposal=validateProposal(extractModel($json),context); return [{json:{requestId:context.requestId,revision:context.revision,executionId:String($execution.id),proposal}}]; } catch(e) { throw new Error('EMF_AI_VALIDATION: '+e.message); }`,1750,0),
  http('Persist draft in Salesforce','draft','={{ JSON.stringify($json) }}',2000,0),
  code('Render offer result',renderPreparation,2250,0),
  iff('Browser response?','respondToBrowser',2500,0),
  response('Return offer result',2750,0),
  node('Return internal result','n8n-nodes-base.code',{jsCode:'return $input.all();'},2750,180,{typeVersion:2}),
  code('Prepare readable AI failure',`const raw=$json.error; const context=$('Build model request').first().json.context; return [{json:{requestId:context.requestId,executionId:String($execution.id),message:'Model AI nie przygotował poprawnej propozycji. Sprawdź połączenie i ponów zlecenie.'}}];`,1750,400),
  http('Persist preparation failure','error','={{ JSON.stringify($json) }}',2000,400),
  code('Explain preparation failure',`return [{json:{...$json,httpStatus:502,title:'Nie udało się przygotować oferty',message:'Połączenie z modelem AI wymaga sprawdzenia. Oferta nie została zatwierdzona. Możesz ponowić to samo zlecenie po usunięciu przyczyny.'}}];`,2250,400),
];
const prepare=workflow(ids.prepare,'EMF · 01 · Przygotuj ofertę',prepNodes,[
 ['Open offer form','Load demo opportunities'],['Load demo opportunities','Render form'],['Render form','Return form'],
 ['Receive preparation','Validate request'],['Receive revision internally','Validate request'],['Validate request','Input valid?'],['Input valid?','Claim and load Salesforce context'],['Input valid?','Render offer result',1],['Claim and load Salesforce context','Generate proposal?'],['Generate proposal?','Build model request'],['Generate proposal?','Render offer result',1],['Build model request','Ask OpenAI'],['Ask OpenAI','Validate AI and calculate price'],['Validate AI and calculate price','Persist draft in Salesforce'],['Persist draft in Salesforce','Render offer result'],['Render offer result','Browser response?'],['Browser response?','Return offer result'],['Browser response?','Return internal result',1],
]);
prepare.nodes.find(n=>n.name==='Validate AI and calculate price').onError='continueErrorOutput';
prepare.connections['Ask OpenAI'].main[1]=[{node:'Prepare readable AI failure',type:'main',index:0}];
prepare.connections['Validate AI and calculate price'].main[1]=[{node:'Prepare readable AI failure',type:'main',index:0}];
prepare.connections['Prepare readable AI failure']={main:[[{node:'Persist preparation failure',type:'main',index:0}]]};
prepare.connections['Persist preparation failure']={main:[[{node:'Explain preparation failure',type:'main',index:0}]]};
prepare.connections['Explain preparation failure']={main:[[{node:'Render offer result',type:'main',index:0}]]};
// Status is deliberately routed to the decision workflow, not the prepare claim endpoint.
const decisionNodes=[
 webhook('Receive decision','POST','emfire/offers/decision',0,0),
 webhook('Read offer status','GET','emfire/offers/status',0,240),
 code('Validate decision',`try {const r=normalize($json.query?.requestId ? {...$json.query,action:'status'} : ($json.body || $json)); if(!['approve','reject','revise','status'].includes(r.action)) throw new Error('Niedozwolona decyzja'); return [{json:{...r,valid:true}}];} catch(e){return [{json:{valid:false,httpStatus:400,code:'INVALID_INPUT',message:e.message}}];}`,250,0),
 iff('Decision valid?','valid',500,0),
 iff('Status request?','isStatus',750,-200),
 code('Route decision',`return [{json:{...$json,isStatus:$json.action==='status'}}];`,750,0),
 http('Read Salesforce offer','status','={{ JSON.stringify($json) }}',1250,-200),
 http('Commit decision atomically','decision','={{ JSON.stringify($json) }}',1250,0),
 iff('Prepare next revision?','regenerate',1500,0),
 node('Prepare next revision','n8n-nodes-base.executeWorkflow',{workflowId:{__rl:true,value:ids.prepare,mode:'id'},workflowInputs:{mappingMode:'defineBelow',value:{requestId:'={{ $json.requestId }}',action:'retry'},schema:[{id:'requestId',displayName:'requestId',type:'string'},{id:'action',displayName:'action',type:'string'}]},mode:'once',options:{waitForSubWorkflow:true}},1750,-100,{typeVersion:1.3}),
 code('Render decision result',render,2000,0),
 response('Return decision result',2250,0),
];
const decision=workflow(ids.decision,'EMF · 02 · Zatwierdź lub popraw ofertę',decisionNodes,[
 ['Receive decision','Validate decision'],['Read offer status','Validate decision'],['Validate decision','Decision valid?'],['Decision valid?','Route decision'],['Decision valid?','Render decision result',1],['Route decision','Status request?'],['Status request?','Read Salesforce offer'],['Status request?','Commit decision atomically',1],['Read Salesforce offer','Render decision result'],['Commit decision atomically','Prepare next revision?'],['Prepare next revision?','Prepare next revision'],['Prepare next revision?','Render decision result',1],['Prepare next revision','Render decision result'],['Render decision result','Return decision result'],
]);
const error=workflow(ids.error,'EMF · 03 · Obsłuż awarię',[
 node('Execution failed','n8n-nodes-base.errorTrigger',{},0,0),
 code('Normalize incident',`const x=$json.execution || {}; return [{json:{executionId:String(x.id || ''),message:('Workflow '+($json.workflow?.name||'')+'; etap '+(x.lastNodeExecuted||'trigger')+'; '+(x.error?.message || $json.trigger?.error?.message || 'Błąd')).slice(0,1800),executionUrl:x.url||null}}];`,250,0),
 http('Mark failed preparation','error','={{ JSON.stringify($json) }}',500,0),
 node('Incident summary','n8n-nodes-base.set',{assignments:{assignments:[{id:'note',name:'note',type:'string',value:'Sprawdź wykonanie źródłowe i ponów z tym samym requestId po usunięciu przyczyny.'}]},includeOtherFields:true,options:{}},750,0,{typeVersion:3.4}),
],[['Execution failed','Normalize incident'],['Normalize incident','Mark failed preparation'],['Mark failed preparation','Incident summary']],{errorWorkflow:undefined});
for(const w of [prepare,decision,error]) fs.writeFileSync(path.join(root,'workflows',w.id+'.json'),JSON.stringify(w,null,2)+'\n');
console.log('Generated 3 inactive n8n workflows. Credentials bound:',Object.keys(cfg).filter(k=>k.endsWith('Credential')).join(', ')||'none');
