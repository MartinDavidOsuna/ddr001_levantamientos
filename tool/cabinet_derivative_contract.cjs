// Read-only API source contract checks. Synthetic images only; no network or database.
const fs=require('fs'),path=require('path'),crypto=require('crypto'),assert=require('assert/strict');
const apiRoot=path.resolve(process.argv[2] || '../ddr001_api');
const {createRequire}=require('module');const req=createRequire(path.join(apiRoot,'package.json')),sharp=req('sharp'),ts=req('typescript');
const folder='build/oversized-fixtures';fs.mkdirSync(folder,{recursive:true});
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
(async()=>{
 const original=await sharp({create:{width:12000,height:6752,channels:3,background:{r:90,g:150,b:70}}}).jpeg({quality:95}).toBuffer();
 for(const [i,size] of [17310456,15942453,19773874,20242426,20256051].entries()) {const bytes=Buffer.alloc(size);original.copy(bytes);fs.writeFileSync(`${folder}/source-${i}.jpg`,bytes);}
 const derived=await sharp(original).resize({width:1920,height:1920,fit:'inside'}).jpeg({quality:82}).toBuffer();fs.writeFileSync(`${folder}/derived.jpg`,derived);
 const src=fs.readFileSync(path.join(apiRoot,'src/modules/cabinets/photos.ts'),'utf8');const ast=ts.createSourceFile('photos.ts',src,ts.ScriptTarget.Latest,true);
 const fn=ast.statements.find(s=>s.name?.text==='uploadCabinetPhoto');let transaction;
 function walk(n){if(ts.isArrowFunction(n)&&n.body?.statements?.some(s=>s.getText(ast).startsWith('const receivedHash')))transaction=n.body;ts.forEachChild(n,walk);}walk(fn);
 const stmts=transaction.statements;const hash=stmts.find(s=>s.getText(ast).startsWith('const receivedHash'));const guard=stmts[stmts.indexOf(hash)+1];const old=stmts[stmts.indexOf(hash)+2];
 const stable=x=>JSON.stringify(x,Object.keys(x).sort());
 const verify=new Function('file','meta','old','id','createHash','stable','cabinetError',hash.getText(ast)+'\n'+guard.getText(ast)+'\nif(old){'+old.thenStatement.statements[0].getText(ast)+'}\nreturn true;');
 const error=(code,msg,status=409)=>{throw Object.assign(Error(msg),{code,status});};
 const id='b0000000-0000-4000-8000-000000000006',meta={photoId:id,clientSha256:sha(derived),context:'registration'};
 assert.equal(verify({buffer:derived},meta,null,id,crypto.createHash,stable,error),true);
 assert.throws(()=>verify({buffer:derived},{...meta,clientSha256:sha(original)},null,id,crypto.createHash,stable,error),e=>e.code==='PHOTO_HASH_MISMATCH'&&e.status===422);
 assert.throws(()=>verify({buffer:derived},meta,{cabinet_id:id,metadata_json:JSON.stringify({...meta,clientSha256:sha(original)})},id,crypto.createHash,stable,error),e=>e.code==='PHOTO_ID_CONFLICT');
 assert.equal(verify({buffer:derived},meta,{cabinet_id:id,metadata_json:JSON.stringify(meta)},id,crypto.createHash,stable,error),true);
 const info=await sharp(derived).metadata();assert(info.width<=1920&&info.height<=1920&&derived.length<6*1024*1024);
 const result={status:'PASS',contract:'Actual uploadCabinetPhoto hash and existing-photo guards executed, no DB/HTTP',sourceDimensions:[12000,6752],sizes:[17310456,15942453,19773874,20242426,20256051],derivativeBytes:derived.length,derivativeDimensions:[info.width,info.height],derivativeSha256:sha(derived),productionRequests:0};fs.writeFileSync('build/oversized-contract-results.json',JSON.stringify(result,null,2));console.log(JSON.stringify(result));
})().catch(e=>{console.error(e);process.exitCode=1;});
