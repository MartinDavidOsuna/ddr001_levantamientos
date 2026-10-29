// Run with backend tsx; credential source stays in the API's ignored TEST profile.
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { writeFile, mkdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
const apiRoot = process.env.CABINETS_API_CHECKOUT;
if (!apiRoot) throw Error('Set CABINETS_API_CHECKOUT to the verified API checkout.');
const { getEnv } = await import(pathToFileURL(resolve(apiRoot, 'src/config/env.ts')).href);
const { db, databaseIdentity, closeDb, sql } = await import(pathToFileURL(resolve(apiRoot, 'src/db/pool.ts')).href);
const env = getEnv();
if (env.NODE_ENV !== 'test' || env.CONFIG_PROFILE !== 'construction-test' || env.SQL_DATABASE !== 'DDR001_Hidrantes_TEST' || resolve(env.STORAGE_ROOT) !== resolve(apiRoot, '.storage/construction-test')) throw Error('Not the isolated TEST profile');
const identity = await databaseIdentity();
if (identity.databaseName !== 'DDR001_Hidrantes_TEST') throw Error('Wrong SQL identity');
const url = 'http://127.0.0.1:3003/api/v1';
const version = await fetch(`${url}/version`).then(r=>r.json());
if (version.environment !== 'test' || !version.commit.startsWith('46b0265b9c8698363f3eca73257bc47382c4d8f2') || !version.features.constructionCabinets) throw Error('Wrong API contract');
const run = randomUUID(), crewId = randomUUID(), baseId = randomUUID(), installationId = randomUUID();
const pool = await db();
try {
 await pool.request().input('id',sql.UniqueIdentifier,crewId).input('name',sql.NVarChar(120),`CABM-${run.slice(0,8)}`).query('INSERT rv.crews(crew_id,name) VALUES(@id,@name)');
 const login = await fetch(`${url}/field-sessions/start`, {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:'Cabinets Mobile TEST', email:`cabm-${run}@example.invalid`,phone:`7${Date.now().toString().slice(-9)}`,crew:'9',client_app:'ddr001_levantamientos',device:{installationId,platform:'android',manufacturer:'TEST',model:'Synthetic Flutter client',androidVersion:'TEST',appVersion:'cabinet-macro2'}})});
 const session = await login.json();
 if (!login.ok) throw Error(`TEST login failed ${login.status}: ${JSON.stringify(session)}`);
 // Provision only this newly-created synthetic identity, never a field user.
 await pool.request().input('id',sql.UniqueIdentifier,session.userId).query("IF EXISTS(SELECT 1 FROM construction.app_users WHERE user_id=@id) UPDATE construction.app_users SET role='resident' WHERE user_id=@id; ELSE INSERT construction.app_users(user_id,role,created_by_source) VALUES(@id,'resident','cabinet_mobile_test')");
 await pool.request().input('id',sql.UniqueIdentifier,baseId).input('actor',sql.UniqueIdentifier,session.userId).input('crew',sql.UniqueIdentifier,crewId).input('label',sql.NVarChar(120),`CABM-TEST-${run.slice(0,8)}`).query("INSERT construction.base_surveys(survey_id,contractor_user_id,display_identifier,status,crew_id) VALUES(@id,@actor,@label,'accepted',@crew)");
 const catalogResponse = await fetch(`${url}/construction/cabinets/catalog`,{headers:{Authorization:`Bearer ${session.accessToken}`}});
 if (!catalogResponse.ok) throw Error('Catalog access failed');
 const catalog = await catalogResponse.json();
 const digits = '26'+String(10000+Math.floor(Math.random()*79999)); let p=10; for(const d of digits){let s=(p+Number(d))%10;if(!s)s=10;p=(s*2)%11;} const uid='AQ'+digits+(11-p)%10;
 const mobile = process.env.CABINETS_MOBILE_CHECKOUT;
 await mkdir(resolve(mobile,'.test-cabinets'),{recursive:true});
 await writeFile(resolve(mobile,'.test-cabinets/session.json'),JSON.stringify({url,identity,apiCommit:version.commit,session,installationId,baseId,uid,run},null,2),{mode:0o600});
 await writeFile(resolve(mobile,'test/cabinets/fixtures/catalog-46b0265.json'),JSON.stringify(catalog,null,2));
 console.log(JSON.stringify({identity,apiCommit:version.commit,baseId,run,storage:env.STORAGE_ROOT}));
} finally {await closeDb();}
