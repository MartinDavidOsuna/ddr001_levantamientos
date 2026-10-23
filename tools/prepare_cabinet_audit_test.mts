// Creates synthetic data only in identity-verified TEST; retains it for audit.
import { randomUUID } from 'node:crypto';
import { writeFile, mkdir } from 'node:fs/promises';
const root=process.env.API_CHECKOUT;
if(!root?.startsWith('/')) throw Error('Set API_CHECKOUT to the absolute local API checkout');
const output=process.env.CABINETS_TEST_SESSION ?? '.test-cabinets/session.json';
await mkdir('.test-cabinets',{recursive:true});
process.env.NODE_ENV='test';
process.env.DOTENV_CONFIG_PATH=root+'/.env.construction-test.local';
process.env.CONFIG_PROFILE='construction-test';
const {databaseIdentity,db,sql,closeDb}=await import(root+'/src/db/pool.ts');
const {issueFieldTokens}=await import(root+'/src/security/jwt.ts');
const {getEnv}=await import(root+'/src/config/env.ts');
if(getEnv().SQL_DATABASE!=='DDR001_Hidrantes_TEST' || getEnv().CONFIG_PROFILE!=='construction-test') throw Error('TEST profile required');
const version=await fetch('http://127.0.0.1:3003/api/v1/version').then(r=>r.json());
if(version.environment!=='test' || !/^[0-9a-f]{40}$/.test(version.commit)) throw Error('TEST API identity required');
const identity=await databaseIdentity();
if(identity.databaseName!=='DDR001_Hidrantes_TEST') throw Error('TEST required');
const pool=await db();
const crew=randomUUID(), baseId=randomUUID();
await pool.request().input('id',sql.UniqueIdentifier,crew).input('name',sql.NVarChar(120),'audit-'+crew).query('INSERT rv.crews(crew_id,name) VALUES(@id,@name)');
const sessions=[];
for(let i=0;i<2;i++){
 const userId=randomUUID(),deviceId=randomUUID(),sessionId=randomUUID(),installationId=randomUUID();
 await pool.request().input('id',sql.UniqueIdentifier,userId).input('crew',sql.UniqueIdentifier,crew).input('email',sql.NVarChar(254),`audit-${userId}@example.invalid`).input('phone',sql.Char(10),String(parseInt(userId.slice(0,8),16)).padStart(10,'0')).query("INSERT rv.users(user_id,full_name,email,phone,default_crew_id) VALUES(@id,N'Auditoría gabinetes TEST',@email,@phone,@crew)");
 await pool.request().input('device',sql.UniqueIdentifier,deviceId).input('installation',sql.UniqueIdentifier,installationId).input('user',sql.UniqueIdentifier,userId).query("INSERT rv.devices(device_id,installation_id,user_id,platform,model,app_version,client_app) VALUES(@device,@installation,@user,'test','audit-test','1','ddr001_levantamientos')");
 await pool.request().input('session',sql.UniqueIdentifier,sessionId).input('user',sql.UniqueIdentifier,userId).input('device',sql.UniqueIdentifier,deviceId).input('crew',sql.UniqueIdentifier,crew).query("INSERT rv.work_sessions(work_session_id,user_id,crew_id,device_id,status,client_app) VALUES(@session,@user,@crew,@device,'open','ddr001_levantamientos')");
 await pool.request().input('user',sql.UniqueIdentifier,userId).query("INSERT construction.app_users(user_id,role,created_by_source) VALUES(@user,'resident','cabinet_test')");
 sessions.push({sessionId,userId,installationId,...issueFieldTokens({userId,deviceId,workSessionId:sessionId})});
}
await pool.request().input('base',sql.UniqueIdentifier,baseId).input('owner',sql.UniqueIdentifier,sessions[0].userId).input('crew',sql.UniqueIdentifier,crew).query("INSERT construction.base_surveys(survey_id,contractor_user_id,display_identifier,status,crew_id) VALUES(@base,@owner,N'Auditoría gabinetes TEST','accepted',@crew)");
const digits='26'+String(10000+Math.floor(Math.random()*70000));let p=10;for(const d of digits){let s=(p+Number(d))%10;if(!s)s=10;p=s*2%11;} const uid='AQ'+digits+((11-p)%10);
await writeFile(output,JSON.stringify({identity,apiCommit:version.commit,session:sessions[0],otherSession:sessions[1],installationId:sessions[0].installationId,baseId,uid}),{mode:0o600});
console.log(JSON.stringify({identity,uid,baseId}));await closeDb();
