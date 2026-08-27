# Reporte de preparación segura — Bloque 1

No se implementó construction, no se creó Flutter, no se ejecutaron migraciones, backups, restores ni escrituras sobre SQL Server/storage.

## 1. Precisiones incorporadas al plan de trabajo

Estas reglas sustituyen las recomendaciones anteriores.

### Finalización completamente offline

La etapa se finaliza localmente sin servidor cuando cumple:

- límites de fotografías;
- archivos físicos locales válidos;
- metadata persistida;
- coordenadas válidas por foto;
- hash y procesamiento local;
- comentario, si existe, persistido.

Flujo definitivo:

```text
FINALIZACIÓN LOCAL
→ INMUTABLE LOCAL
→ SYNC DE DOMINIO/MEDIA PENDIENTE
→ UPLOAD
→ VERIFY-BATCH
→ CONFIRMED
```

El contractor puede completar las seis etapas y alcanzar `EXECUTED_LOCAL` sin Internet. Deben separarse estado funcional local, estado funcional reconocido por servidor, estado de sincronización e integridad fotográfica.

### Coordenada canónica

La coordenada canónica será la de la primera fotografía válida del Paso 1 — Preparación del terreno.

Reglas:

- debe superar la misma validación GPS que una evidencia;
- se asigna localmente cuando esa foto pasa a `LOCATION_READY`;
- se sincroniza junto al survey/foto;
- queda estable;
- ninguna foto posterior mueve el pin;
- contractor no puede modificarla;
- resident podrá corregirla mediante acción auditada;
- un survey sin foto válida del Paso 1 aparece en listas, pero no en el mapa.

### Identificador duplicado

- No habrá `UNIQUE` SQL sobre `display_identifier`.
- Duplicado propio local conocido: bloquear.
- Duplicado propio conocido por servidor: bloquear.
- No se ofrecerá “Crear de todos modos”.
- Si se crea offline porque el duplicado remoto era desconocido, la API acepta el UUID.
- Al reconciliar, la coincidencia se reporta como incidencia/advisory; no se fusionan surveys.

No se modificó el archivo local del plan en este bloque.

## 2. Baseline API hardened

| Elemento | Resultado |
|---|---|
| Rama | `feature/photo-sync-integrity-hardening` |
| SHA local | `54c76daa84d78c2f370de366a5f058cd0794bdf7` |
| SHA origin | `54c76daa84d78c2f370de366a5f058cd0794bdf7` |
| Coincidencia | Exacta |
| Worktree | Limpio |
| Acción | Sólo `fetch --all --prune`; no merge/rebase/push |

Este será el punto de partida futuro de `feature/construction-field-app`.

## 3. Baseline RV hardened

| Elemento | Resultado |
|---|---|
| Rama | `feature/photo-sync-integrity-hardening` |
| SHA local inicial | `e6b7438fd48d8b3b38d10bf520ffc8ceb3f5b7b4` |
| Existía inicialmente en origin | No |
| Push de preservación | Exitoso, push normal |
| SHA origin final | `e6b7438fd48d8b3b38d10bf520ffc8ceb3f5b7b4` |
| Coincidencia local/remoto | Exacta |
| Tracking | Configurado contra origin |
| Worktree | Limpio |
| Merge/rebase/force-push | Ninguno |

La rama hardened RV ya está preservada remotamente.

## 4. Estado de `ddr001_levantamientos`

El remoto GitHub continúa realmente vacío: no devuelve ninguna rama.

El directorio local no está completamente vacío porque contiene `PLAN_TECNICO_PRIMER_BUILD.md`, creado por solicitud expresa en el turno anterior. Sigue sin `.git`, Flutter, Android/iOS, código, SSOT o rama. No se modificó en este bloque.

## 5. SQL Server y producción

| Elemento | Valor confirmado |
|---|---|
| `@@SERVERNAME` | `WIN-5RQE8N8NQ9V` |
| `DB_NAME()` | `DDR001_Hidrantes_Prod` |
| ProductVersion | `12.0.4237.0` |
| ProductLevel | `SP1` |
| Edition | Standard Edition 64-bit |
| Recovery | `FULL` |
| Estado | `ONLINE`, `MULTI_USER` |
| Read-only | No |
| Auto-close | No |
| Service Broker | Habilitado |
| CDC | Deshabilitado |
| Cuenta actual | `cifra_agri` |
| Sysadmin | Sí |
| `BACKUP DATABASE` | Sí |
| `ALTER DATABASE` | Sí |
| `CREATE ANY DATABASE` | Sí |

La cuenta usada actualmente por la API está excesivamente privilegiada.

## 6. Existencia de TEST

`DB_ID('DDR001_Hidrantes_TEST') = NULL`. TEST no existe y no se creó.

## 7. Archivos y espacio

| Archivo | Lógico | Ruta física | Tamaño | Usado |
|---|---|---|---:|---:|
| Datos | `DDR001_Hidrantes_Prod` | `C:\Servicios IT\BasesDeDatos\MSSQL\Data\DDR001_Hidrantes_Prod.mdf` | 111 MB | 110.25 MB |
| Log | `DDR001_Hidrantes_Prod_log` | `C:\Servicios IT\BasesDeDatos\MSSQL\Data\DDR001_Hidrantes_Prod_log.ldf` | 5.06 MB | 3.05 MB |

- Espacio libre C: 879,672 MB (~859 GB).
- Default data/log: `C:\Servicios IT\BasesDeDatos\MSSQL\Data`.
- Default backup: `C:\Servicios IT\BasesDeDatos\MSSQL\Backup` (existe).

Rutas TEST propuestas:

```text
C:\Servicios IT\BasesDeDatos\MSSQL\Data\DDR001_Hidrantes_TEST.mdf
C:\Servicios IT\BasesDeDatos\MSSQL\Data\DDR001_Hidrantes_TEST_log.ldf
```

## 8. Estrategia real de backups encontrada

- No hay backup history de producción DDR001.
- No hay backup devices, Maintenance Plans ni jobs con `BACKUP DATABASE`.
- Ningún job referencia DDR001.
- `msdb` sólo contiene cinco backups históricos de otras bases (2016–2024).

Clasificación: **D — no se puede determinar completamente**. No hay mecanismo interno visible para DDR001, pero no pueden descartarse Task Scheduler, PowerShell externo, Veeam/VM snapshots, scripts manuales o historial purgado.

## 9. SQL Agent jobs

| Job | Owner | DB/Subsystem | Schedule | Riesgo TEST |
|---|---|---|---|---|
| Actualiza UUIDs | Administrador Windows | T-SQL `DB_Agrienlace` | Diario/cada hora desde 05:00 | Ninguno directo |
| Acumula Saldos Históricos | `cifra` | T-SQL `DB_Agrienlace` | Mensual, día 1 04:00 | Ninguno directo |
| Sync Dolar desde SERVAQ | `agri_cifra` | T-SQL `DB_Agrienlace` | Cada 15 min 07:00–11:59 | Ninguno directo |
| syspolicy_purge_history | `sa` | master/msdb + PowerShell | Diario 02:00 | Ninguno para datos TEST |

No hay proxies SQL Agent. Ningún step contiene rutas API/storage, DDR001 o backup. Existe el linked server `SERVAQ_LINKED → 187.141.184.162,1433`, asociado al flujo `DB_Agrienlace`, no a DDR001.

## 10. Integraciones internas relevantes

- Broker: sólo tres servicios internos, sin conversaciones ni activation procedures.
- CDC deshabilitado.
- Database Mail vacío.
- Sin server triggers ni Maintenance Plans.
- Dos triggers internos de coordenadas en `rv.hydrants`; deben preservarse.
- Sin external users/groups.

## 11. Script 01 — precheck read-only

Ruta conceptual: `sql/construction/test-env/01_precheck_readonly.sql`.

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME() <> N'DDR001_Hidrantes_Prod'
    THROW 51000, 'REFUSED: precheck must run on production.', 1;

SELECT @@SERVERNAME server_name, DB_NAME() database_name,
 CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) product_version,
 CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(128)) product_level,
 CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) edition,
 CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(4000)) default_data_path,
 CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(4000)) default_log_path;

SELECT name,state_desc,user_access_desc,recovery_model_desc,is_read_only,
 is_auto_close_on,is_broker_enabled,is_cdc_enabled
FROM sys.databases
WHERE name IN(N'DDR001_Hidrantes_Prod',N'DDR001_Hidrantes_TEST');

SELECT DB_ID(N'DDR001_Hidrantes_TEST') test_database_id;

SELECT name logical_name,type_desc,physical_name,
 CONVERT(decimal(18,2),size*8.0/1024) size_mb,
 CONVERT(decimal(18,2),FILEPROPERTY(name,'SpaceUsed')*8.0/1024) used_mb,
 growth,is_percent_growth,max_size
FROM sys.database_files ORDER BY type;

SELECT HAS_PERMS_BY_NAME(DB_NAME(),'DATABASE','BACKUP DATABASE') can_backup,
 HAS_PERMS_BY_NAME(DB_NAME(),'DATABASE','ALTER') can_alter,
 HAS_PERMS_BY_NAME(NULL,NULL,'CREATE ANY DATABASE') can_create_database,
 IS_SRVROLEMEMBER('sysadmin') is_sysadmin,
 ORIGINAL_LOGIN() original_login,SUSER_SNAME() effective_login;

DECLARE @Data nvarchar(4000),@Log nvarchar(4000),@Backup nvarchar(4000);
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
 N'Software\Microsoft\MSSQLServer\MSSQLServer',N'DefaultData',@Data OUTPUT;
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
 N'Software\Microsoft\MSSQLServer\MSSQLServer',N'DefaultLog',@Log OUTPUT;
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
 N'Software\Microsoft\MSSQLServer\MSSQLServer',N'BackupDirectory',@Backup OUTPUT;
SELECT @Data default_data,@Log default_log,@Backup default_backup;
EXEC master.dbo.xp_fixeddrives;

SELECT bs.database_name,bs.type,bs.is_copy_only,bs.has_backup_checksums,
 bs.backup_start_date,bs.backup_finish_date,bmf.physical_device_name
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id=bs.media_set_id
WHERE bs.database_name=N'DDR001_Hidrantes_Prod'
ORDER BY bs.backup_finish_date DESC;
```

No se creó el archivo.

## 12. Script 02 — backup COPY_ONLY (no ejecutado)

```sql
USE [master];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_ID(N'DDR001_Hidrantes_Prod') IS NULL THROW 51000,'Production missing.',1;
IF DB_ID(N'DDR001_Hidrantes_TEST') IS NOT NULL THROW 51001,'TEST exists.',1;

DECLARE @Stamp char(15),@File nvarchar(4000),@Name nvarchar(256),
 @Exists int,@Sql nvarchar(max);
SET @Stamp=CONVERT(char(8),GETDATE(),112)+N'_'
 +REPLACE(CONVERT(char(8),GETDATE(),108),N':',N'');
SET @File=N'C:\Servicios IT\BasesDeDatos\MSSQL\Backup\DDR001_Hidrantes_Prod_COPY_ONLY_'+@Stamp+N'.bak';
SET @Name=N'DDR001_Hidrantes_Prod COPY_ONLY '+@Stamp;
EXEC master.dbo.xp_fileexist @File,@Exists OUTPUT;
IF ISNULL(@Exists,0)<>0 THROW 51002,'Backup target exists.',1;

SET @Sql=N'BACKUP DATABASE [DDR001_Hidrantes_Prod] TO DISK='
 +QUOTENAME(@File,N'''')+N' WITH COPY_ONLY,CHECKSUM,INIT,NAME='
 +QUOTENAME(@Name,N'''')+N',STATS=10;';
SELECT @File planned_backup_file;
EXEC sys.sp_executesql @Sql;
SET @Sql=N'RESTORE VERIFYONLY FROM DISK='+QUOTENAME(@File,N'''')+N' WITH CHECKSUM;';
EXEC sys.sp_executesql @Sql;
GO
```

## 13. Script 03 — restore TEST (no ejecutado)

```sql
USE [master];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @Backup nvarchar(4000)=N'C:\Servicios IT\BasesDeDatos\MSSQL\Backup\<APPROVED>.bak',
 @Data nvarchar(4000)=N'C:\Servicios IT\BasesDeDatos\MSSQL\Data\DDR001_Hidrantes_TEST.mdf',
 @Log nvarchar(4000)=N'C:\Servicios IT\BasesDeDatos\MSSQL\Data\DDR001_Hidrantes_TEST_log.ldf',
 @Exists int,@Sql nvarchar(max);
IF DB_ID(N'DDR001_Hidrantes_TEST') IS NOT NULL
 THROW 51001,'TEST exists; WITH REPLACE forbidden.',1;
EXEC master.dbo.xp_fileexist @Backup,@Exists OUTPUT;
IF ISNULL(@Exists,0)=0 THROW 51002,'Backup missing.',1;
SET @Exists=0; EXEC master.dbo.xp_fileexist @Data,@Exists OUTPUT;
IF ISNULL(@Exists,0)<>0 THROW 51003,'Target MDF exists.',1;
SET @Exists=0; EXEC master.dbo.xp_fileexist @Log,@Exists OUTPUT;
IF ISNULL(@Exists,0)<>0 THROW 51004,'Target LDF exists.',1;

SET @Sql=N'RESTORE FILELISTONLY FROM DISK='+QUOTENAME(@Backup,N'''')+N';';
EXEC sys.sp_executesql @Sql;
/* El operador valida nombres lógicos antes de continuar. */
SET @Sql=N'RESTORE DATABASE [DDR001_Hidrantes_TEST] FROM DISK='
 +QUOTENAME(@Backup,N'''')+N' WITH MOVE N''DDR001_Hidrantes_Prod'' TO '
 +QUOTENAME(@Data,N'''')+N',MOVE N''DDR001_Hidrantes_Prod_log'' TO '
 +QUOTENAME(@Log,N'''')+N',RECOVERY,CHECKSUM,STATS=10;';
EXEC sys.sp_executesql @Sql;

SELECT name,state_desc,recovery_model_desc FROM sys.databases
WHERE name=N'DDR001_Hidrantes_TEST';
SELECT N'rv.users' entity,COUNT_BIG(*) row_count FROM DDR001_Hidrantes_TEST.rv.users
UNION ALL SELECT N'rv.hydrants',COUNT_BIG(*) FROM DDR001_Hidrantes_TEST.rv.hydrants
UNION ALL SELECT N'rv.inspections',COUNT_BIG(*) FROM DDR001_Hidrantes_TEST.rv.inspections
UNION ALL SELECT N'rv.photos',COUNT_BIG(*) FROM DDR001_Hidrantes_TEST.rv.photos;
DBCC CHECKDB(N'DDR001_Hidrantes_TEST') WITH NO_INFOMSGS,ALL_ERRORMSGS;
/* SIMPLE sólo tras aprobación. */
GO
```

## 14. Script 04 — aislamiento post-restore (no ejecutado)

```sql
USE [DDR001_Hidrantes_TEST];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME()=N'DDR001_Hidrantes_Prod' THROW 51000,'REFUSED production.',1;
IF DB_NAME()<>N'DDR001_Hidrantes_TEST' THROW 51001,'Wrong database.',1;
IF @@SERVERNAME<>N'WIN-5RQE8N8NQ9V' THROW 51002,'Unexpected server.',1;
BEGIN TRY
 BEGIN TRANSACTION;
 UPDATE rv.refresh_tokens SET revoked_at=COALESCE(revoked_at,SYSUTCDATETIME())
 WHERE revoked_at IS NULL;
 UPDATE rv.work_sessions SET status='revoked',ended_at=COALESCE(ended_at,SYSUTCDATETIME())
 WHERE status='open';
 UPDATE rv.persistent_field_sessions SET status='revoked',
  revoked_at=COALESCE(revoked_at,SYSUTCDATETIME()),
  revoked_reason=COALESCE(revoked_reason,N'Neutralized after TEST restore'),
  revocation_epoch=revocation_epoch+1 WHERE status='active';
 UPDATE rv.device_bindings SET status='revoked',
  revoked_at=COALESCE(revoked_at,SYSUTCDATETIME()),
  revoked_reason=COALESCE(revoked_reason,N'Neutralized after TEST restore'),
  revocation_epoch=revocation_epoch+1 WHERE status='active';
 UPDATE rv.admin_users SET is_active=0 WHERE is_active=1;
 COMMIT;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK;
 THROW;
END CATCH;
GO
```

Se preservan usuarios, hidrantes, revisiones, fotos, catálogos y triggers internos. Después se crea un admin TEST dedicado; no se reactivan admins clonados.

## 15. Credenciales TEST propuestas

Runtime `DDR001_Levantamientos_TEST_Runtime`: CONNECT y SELECT/INSERT/UPDATE/DELETE/EXECUTE sólo en schemas `rv` y posteriormente `construction`; sin DDL, backup, restore, create database, producción, linked servers o sysadmin.

Migrator `DDR001_Levantamientos_TEST_Migrator`: sólo TEST, CREATE SCHEMA/TABLE/PROCEDURE/FUNCTION/VIEW, ALTER ANY SCHEMA, REFERENCES y DML necesarios; se deshabilita después de migrar.

```sql
/* TEMPLATE: passwords injected by secret manager. */
CREATE LOGIN [DDR001_Levantamientos_TEST_Runtime]
WITH PASSWORD=N'<RUNTIME_PASSWORD>',CHECK_POLICY=ON,CHECK_EXPIRATION=ON,
 DEFAULT_DATABASE=[DDR001_Hidrantes_TEST];
USE [DDR001_Hidrantes_TEST];
CREATE USER [DDR001_Levantamientos_TEST_Runtime]
 FOR LOGIN [DDR001_Levantamientos_TEST_Runtime];
GRANT CONNECT TO [DDR001_Levantamientos_TEST_Runtime];
GRANT SELECT,INSERT,UPDATE,DELETE ON SCHEMA::rv
 TO [DDR001_Levantamientos_TEST_Runtime];
GRANT EXECUTE ON SCHEMA::rv TO [DDR001_Levantamientos_TEST_Runtime];
/* Repetir grants sobre construction después de que exista. */
```

## 16. Storage TEST

Ruta: `C:\APIS\DDR001-Hidrantes-TEST\storage`.

SQL Server no ve el storage productivo, por lo que probablemente pertenece al host API. Debe validarse en ese host. Se propone identidad Windows dedicada, ACL Modify sólo sobre TEST, sin acceso al root productivo, path absoluto, integrity job deshabilitado y guardas de limpieza que exijan root TEST exacto, descendencia, rechazo de junctions/symlinks y de targets amplios.

No se creó directorio ni ACL.

## 17. Configuración API TEST

```dotenv
NODE_ENV=test
PORT=3003
SQL_SERVER=cifra.agrienlace.com
SQL_PORT=11333
SQL_DATABASE=DDR001_Hidrantes_TEST
SQL_USER=DDR001_Levantamientos_TEST_Runtime
SQL_PASSWORD=<SECRET_MANAGER>
SQL_ENCRYPT=false
SQL_TRUST_SERVER_CERTIFICATE=true
STORAGE_ROOT=C:\APIS\DDR001-Hidrantes-TEST\storage
FIELD_JWT_SECRET=<TEST_ONLY>
FIELD_REFRESH_SECRET=<TEST_ONLY>
ADMIN_JWT_SECRET=<TEST_ONLY>
ADMIN_REFRESH_SECRET=<TEST_ONLY>
CORS_ORIGINS=https://<TEST_ADMIN_HOST>
PUBLIC_BASE_URL=https://<TEST_API_HOST>
PHOTO_INTEGRITY_JOB_ENABLED=false
SQL_PRODUCTION_DATABASE=DDR001_Hidrantes_Prod
```

No se modificó `.env`.

## 18. Estrategia HTTPS/API TEST

Estado real:

- `cifra.aquafim.com` → `187.141.184.162`.
- HTTP puerto 3002 responde 200.
- HTTPS 443 presenta certificado `CN=monitoreo.agrienlace.com`, no coincidente y con cadena no verificable.
- 3002 no sirve TLS válido.
- La documentación recomienda IIS ARR, pero no demuestra binding HTTPS correcto.

Propuesta:

```text
Internet → HTTPS 443 → levantamientos-test-api.aquafim.com
→ IIS ARR/URL Rewrite → 127.0.0.1:3003 → API TEST
```

DNS dedicado, certificado público válido con SAN, cadena completa, binding SNI separado, puerto interno no público, forwarded headers, límite 9–10 MB, secretos/CORS/URL TEST y bloqueo web de `.env`/storage. Flutter no tendrá excepción HTTP.

## 19. Bloqueos humanos reales

1. Confirmar backups externos/Task Scheduler/snapshots.
2. Autorizar backup COPY_ONLY.
3. Confirmar permisos/retención de la ruta backup.
4. Validar FILELISTONLY antes del restore.
5. Aprobar rutas MDF/LDF.
6. Identificar host/gestor real de API (NSSM/PM2).
7. Validar storage en ese host y ACL TEST.
8. Crear identidades SQL sin sysadmin.
9. Elegir hostname y gestionar DNS/certificado.
10. Definir custodia de secretos TEST.
11. Crear admin TEST nuevo tras neutralización.
12. Aprobar o no recovery SIMPLE.
13. Decidir incorporación del plan existente al futuro repo.

El punto seguro de detención se alcanzó. No se ejecutó ninguna modificación sobre SQL Server, storage ni Flutter.
