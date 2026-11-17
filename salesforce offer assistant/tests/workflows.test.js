const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');
const {test}=require('node:test');const assert=require('node:assert/strict');
const dir=path.join(__dirname,'../workflows');
const workflows=fs.readdirSync(dir).filter(f=>f.endsWith('.json')).map(f=>JSON.parse(fs.readFileSync(path.join(dir,f),'utf8')));
test('exactly three distinct inactive workflows with resolvable edges',()=>{
 assert.equal(workflows.length,3);assert.equal(new Set(workflows.map(w=>w.id)).size,3);
 for(const w of workflows){assert.equal(w.active,false);const names=new Set(w.nodes.map(n=>n.name));assert.equal(names.size,w.nodes.length);for(const [src,outputs] of Object.entries(w.connections)){assert.ok(names.has(src));for(const ports of Object.values(outputs))for(const edges of ports)for(const e of edges||[])assert.ok(names.has(e.node),e.node);}}
});
test('all webhook entry points require authentication',()=>{
 const hooks=workflows.flatMap(w=>w.nodes).filter(n=>n.type==='n8n-nodes-base.webhook');assert.equal(hooks.length,4);assert.ok(hooks.every(n=>n.parameters.authentication==='basicAuth'));
});
test('generated Code nodes parse as async function bodies',()=>{
 for(const w of workflows)for(const n of w.nodes.filter(n=>n.type==='n8n-nodes-base.code'))assert.doesNotThrow(()=>new vm.Script('(async function(){'+n.parameters.jsCode+'\n})'),n.name);
});
test('approval workflow cannot call an LLM',()=>{
 const w=workflows.find(w=>w.id==='EMFOfferDecide01');assert.ok(!w.nodes.some(n=>n.parameters.url?.startsWith('https://api.openai.com/')));
 const commit=w.nodes.find(n=>n.name==='Commit decision atomically');assert.ok(commit.parameters.url.endsWith('/decision'));
});
test('prepared revision returns through an internal branch, not a webhook response',()=>{
 const w=workflows.find(w=>w.id==='EMFOfferPrepare1');assert.equal(w.connections['Browser response?'].main[1][0].node,'Return internal result');
});
test('bounded HTTP attempts and dedicated error workflow',()=>{
 for(const w of workflows){for(const n of w.nodes.filter(n=>n.type==='n8n-nodes-base.httpRequest')){if(n.name==='Ask OpenAI'){assert.equal(n.retryOnFail,false);assert.equal(n.onError,'continueErrorOutput');}else assert.equal(n.maxTries,3);assert.ok(n.parameters.options.timeout<=45000);}if(w.id!=='EMFOfferError001')assert.equal(w.settings.errorWorkflow,'EMFOfferError001');}
});
test('model transport and validation failures have a response and persistent recovery state',()=>{
 const w=workflows.find(w=>w.id==='EMFOfferPrepare1');
 for(const name of ['Ask OpenAI','Validate AI and calculate price'])assert.equal(w.connections[name].main[1][0].node,'Prepare readable AI failure');
 assert.equal(w.connections['Persist preparation failure'].main[0][0].node,'Explain preparation failure');
 assert.equal(w.connections['Explain preparation failure'].main[0][0].node,'Render offer result');
});

test('GET status works when n8n includes an empty body object',async()=>{
 const w=workflows.find(w=>w.id==='EMFOfferDecide01'); const js=w.nodes.find(n=>n.name==='Validate decision').parameters.jsCode;
 const run=vm.runInNewContext('(async function($json){'+js+'\n})');
 const out=await run({body:{},query:{requestId:'demo-status-0001'}});
 assert.equal(out[0].json.valid,true);assert.equal(out[0].json.action,'status');assert.equal(out[0].json.requestId,'demo-status-0001');
});
