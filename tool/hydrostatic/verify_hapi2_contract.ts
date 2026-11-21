import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
// Read-only API contract exercise. No SQL, HTTP, credentials or field data.
// Run with the API's installed tsx; see docs/hydrostatic-sync-test.md.
(async()=>{
const apiRoot=resolve(process.argv[2]);
const { HydrostaticRepository }=await import(pathToFileURL(resolve(apiRoot,'src/modules/hydrostatic/repository.ts')).href);
const { commandSchema,payloadSchema }=await import(pathToFileURL(resolve(apiRoot,'src/modules/hydrostatic/schemas.ts')).href);
const commands=JSON.parse(readFileSync(process.argv[3],'utf8'));
const tests=new Map(),operations=new Map(),hashes=new Map();
let commits=0;
const devices=new Map();
const repository=new HydrostaticRepository({transaction: async(fn:any)=>fn({
 authorize:async()=>{}, operation:async(id:string)=>operations.get(id)??null,
 test:async(id:string)=>tests.get(id)??null,
 documentHash:async(id:string,r:number)=>hashes.get(`${id}:${r}`)??null,
 requireCabinet:async(id:string,uid:string)=>{if(!id||uid!=='AQ26980015')throw Error('Cabinet fixture invalid');},
 commit:async(m:any)=>{
  commits++;
  operations.set(m.command.operationId,{fingerprint:m.fingerprint,receipt:m.receipt,actorId:m.identity.userId,installationId:m.identity.installationId});
  tests.set(m.testId,{payloadJson:m.command.payloadJson,sourceHash:m.command.payloadSha256,serverVersion:m.receipt.serverVersion,originDeviceId:m.identity.originDeviceId});
  hashes.set(`${m.testId}:${m.payload.document.revision}`,m.command.payloadSha256);
 }
})});
 for(const raw of commands){
  const c=commandSchema.parse(raw),p=payloadSchema.parse(JSON.parse(c.payloadJson));
  const a=p.document.actor;
  if(!devices.has(a.deviceInstallationId))devices.set(a.deviceInstallationId,randomUUID());
  const device=devices.get(a.deviceInstallationId);
  const identity={kind:'field',role:'resident',accessEnabled:true,userId:a.userId,sessionId:a.sessionId,deviceId:device,installationId:a.deviceInstallationId,originSessionId:a.sessionId,originDeviceId:device,originInstallationId:a.deviceInstallationId} as const;
  const receipt=await repository.execute(p.document.id,c,identity);
  if(receipt.acceptedSourceHash!==c.payloadSha256)throw Error('Hash mismatch');
  const before=commits;
  const replay=await repository.execute(p.document.id,c,identity);
  if(JSON.stringify(receipt)!==JSON.stringify(replay)||commits!==before)throw Error('Replay changed receipt');
 }
 console.log(`PASS: ${commands.length} Flutter checkpoints validated and committed with actual HAPI-2 repository; ${commands.length} exact replays; ${tests.size} synthetic dossiers. SQL/HTTP not used.`);
 console.log([...tests.values()].map((t:any)=>{const d=JSON.parse(t.payloadJson).document;return {state:d.state,result:d.result,discarded:!!d.discardedAt,timeState:d.timeState};}));
})().catch(e=>{console.error(e);process.exitCode=1;});
