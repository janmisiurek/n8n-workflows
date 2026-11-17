const {test}=require('node:test');
const assert=require('node:assert/strict');
const core=require('../src/core');
const context={revision:1,customer:{name:'Demo <script>alert(1)</script>',contactName:'Anna Demo'},opportunity:{id:'006000000000001AAA'},catalog:[{productCode:'EMF_START',name:'Start',description:'jeden proces',unitMinor:299999,currency:'PLN'},{productCode:'EMF_TEAM',name:'Zespół',description:'dwa procesy',unitMinor:600000,currency:'PLN'}]};
const proposal=()=>({summary:'Automatyzacja zapytań',items:[{productCode:'EMF_START',quantity:3}],assumptions:['Jeden proces'],questions:[]});
test('request normalization rejects invalid opportunity IDs and actions',()=>{
 assert.throws(()=>core.normalize({requestId:'demo-0001',opportunityId:'Account',instruction:'x'}));
 assert.throws(()=>core.normalize({requestId:'demo-0001',action:'delete'}));
});
test('revisions require a positive integer and feedback',()=>{
 assert.throws(()=>core.normalize({requestId:'demo-0001',action:'approve',revision:1.5}));
 assert.throws(()=>core.normalize({requestId:'demo-0001',action:'revise',revision:1,feedback:' '}));
 assert.equal(core.normalize({requestId:'demo-0001',action:'approve',revision:'2'}).revision,2);
});
test('calculates money in integer minor units from Salesforce catalog',()=>{
 const p=core.validateProposal(proposal(),context);assert.equal(p.totalMinor,899997);assert.equal(p.lines[0].unitMinor,299999);
});
test('LLM cannot inject prices or unrecognized fields',()=>{
 const p=proposal();p.items[0].unitMinor=1;assert.throws(()=>core.validateProposal(p,context));
 const q=proposal();q.discount=99;assert.throws(()=>core.validateProposal(q,context));
});
test('unknown products and duplicates are rejected',()=>{
 const p=proposal();p.items[0].productCode='CHEAP';assert.throws(()=>core.validateProposal(p,context));
 const q=proposal();q.items.push({...q.items[0]});assert.throws(()=>core.validateProposal(q,context));
});
test('negative fractional and excessive quantities are rejected',()=>{
 for(const quantity of [-1,0,1.2,11,'2',null]){const p=proposal();p.items[0].quantity=quantity;assert.throws(()=>core.validateProposal(p,context));}
});
test('missing data may return questions without invented line items',()=>{
 const p=proposal();p.items=[];p.questions=['Jaki proces?'];assert.equal(core.validateProposal(p,context).totalMinor,0);
 p.questions=[];assert.throws(()=>core.validateProposal(p,context));
});
test('schema rejects malformed questions and bad catalog data',()=>{
 const p=proposal();p.questions='question';assert.throws(()=>core.validateProposal(p,context));
 const c=structuredClone(context);c.catalog[0].unitMinor=1.01;assert.throws(()=>core.validateProposal(proposal(),c));
});
const response=(content,status='completed')=>({status,output:[{type:'message',status:'completed',content}]});
test('OpenAI completed JSON is parsed; reasoning items are ignored',()=>{
 const r=response([{type:'output_text',text:JSON.stringify(proposal())}]);r.output.unshift({type:'reasoning',summary:[]});
 assert.deepEqual(core.extractModel(r),proposal());
});
test('OpenAI refusal incomplete output empty output and malformed JSON fail closed',()=>{
 assert.throws(()=>core.extractModel(response([{type:'refusal',refusal:'no'}])));
 assert.throws(()=>core.extractModel(response([{type:'output_text',text:'{}'}],'incomplete')));
 assert.throws(()=>core.extractModel({status:'completed',output:[]}));
 assert.throws(()=>core.extractModel(response([{type:'output_text',text:'broken'}])));
 const r=response([{type:'output_text',text:'{}'}]);r.output[0].status='incomplete';assert.throws(()=>core.extractModel(r));
});
test('OpenAI schema restricts products and extra fields without storing response',()=>{
 const r=core.modelRequest(context); assert.equal(r.store,false);assert.equal(r.text.format.strict,true);
 assert.equal(r.text.format.schema.additionalProperties,false);
 assert.deepEqual(r.text.format.schema.properties.items.items.properties.productCode.enum,['EMF_START','EMF_TEAM']);
});
test('minimal model input does not include prices or contact email',()=>{
 const c=structuredClone(context);c.customer.contactEmail='private@example.com';
 const request=core.modelRequest(c);assert.ok(!JSON.stringify(request).includes('unitMinor'));
 assert.ok(!JSON.stringify(request).includes('private@example.com'));
});
test('rendering escapes customer model feedback and form values',()=>{
 const p=core.validateProposal(proposal(),context);p.summary='<img src=x onerror=alert(1)>';
 const html=core.documentHtml(context,p);assert.ok(!html.includes('<script>'));assert.ok(!html.includes('<img '));assert.ok(html.includes('&lt;img'));
 const result=core.renderResult({status:'REVIEW',requestId:'x" onmouseover="alert(1)',revision:1,proposal:p},'http://localhost:5678');assert.ok(!result.includes('value="x" onmouseover='));
});
test('questions prevent an approval action in the UI',()=>{
 const p=core.validateProposal({...proposal(),questions:['Która skrzynka?']},context);
 const html=core.renderResult({status:'NEEDS_INPUT',requestId:'demo-0001',revision:1,proposal:p},'http://localhost:5678');assert.ok(!html.includes('value="approve"'));assert.ok(html.includes('value="revise"'));
});

test('Salesforce links navigate in the current tab so n8n CSP sandbox is not inherited by a popup',()=>{
 const html=core.renderResult({status:'READY',documentUrl:'https://example.lightning.force.com/lightning/r/ContentDocument/069demo/view',recordUrl:'https://example.lightning.force.com/lightning/r/Demo_Offer__c/a00demo/view'},'http://localhost:5678');
 assert.equal((html.match(/target="_self"/g)||[]).length,2);
 assert.ok(!html.includes('target="_blank"'));
});
