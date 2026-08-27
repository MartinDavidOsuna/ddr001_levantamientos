# Creación manual de DDR001_Hidrantes_TEST

Fecha de preparación: 2026-08-26. Compatible con SQL Server 2014 (12.x).

## Alcance y reglas

Estos archivos son para que un operador autorizado los ejecute manualmente en SSMS sobre `WIN-5RQE8N8NQ9V`. Codex no ejecutó SQL ni accedió al servidor. No se debe usar IIS, storage productivo ni credenciales productivas durante este procedimiento.

Antes de empezar, abra SSMS como un operador con permisos suficientes para backup/restore y creación de logins. Active **Results to Grid**. Ejecute cada archivo completo y en orden; no seleccione fragmentos internos.

## PASO 1 — Precheck de sólo lectura

Ejecute [01_precheck.sql](01_precheck.sql).

Resultado esperado:

- `server_name_check = OK` y servidor `WIN-5RQE8N8NQ9V`.
- SQL Server 12.0.4237.0 SP1, edición Standard (o la descripción equivalente devuelta por la instancia).
- Producción existe y TEST no existe.
- Se muestran recovery, archivos, logical names, tamaños, rutas default y permisos del operador.

**DETÉNGASE** si aparece un error, si TEST ya existe, si producción no es `ONLINE`, si el servidor no coincide o si las rutas no son `C:\Servicios IT\BasesDeDatos\MSSQL\Data` y `C:\Servicios IT\BasesDeDatos\MSSQL\Backup`. No intente corregirlo borrando nada.

## PASO 2 — Backup COPY_ONLY

Ejecute [02_backup_copy_only.sql](02_backup_copy_only.sql). El script calcula un timestamp `yyyyMMdd_HHmmss`, comprueba que el `.bak` no exista, realiza `COPY_ONLY, CHECKSUM, INIT, STATS=10` y termina con `RESTORE VERIFYONLY WITH CHECKSUM`.

Resultado esperado: mensajes de progreso, `VERIFYONLY` exitoso y una fila final con `backup_file`. **Copie esa ruta exacta**; se usa en los pasos 3 y 4.

**DETÉNGASE** si el archivo ya existe, si falla `CHECKSUM`, backup o `VERIFYONLY`, o si la ruta final no está bajo el directorio de backup confirmado.

## PASO 3 — FILELISTONLY

Abra [03_filelistonly.sql](03_filelistonly.sql), reemplace exactamente `<BACKUP_FILE>` por la ruta obtenida en el paso 2 y ejecútelo.

Copie/verifique de cada fila:

- `LogicalName`: es el valor que se pondrá en cada `MOVE`; no se debe adivinar.
- `PhysicalName`: sólo informa el origen; no se reutiliza para TEST.
- `Type`: `D` es data y `L` es log.
- `FileId`, `FileGroupName`, `Size`, `MaxSize`: sirven para detectar archivos adicionales o tamaños incompatibles.

El script de restore provisto admite exactamente **un archivo de datos y un archivo de log**. **DETÉNGASE** y reporte el FILELISTONLY completo si hay más de una fila `D`, más de una fila `L`, FILESTREAM (`Type = S`) u otro tipo. No improvise rutas adicionales.

## PASO 4 — Restaurar TEST

Abra [04_restore_test.sql](04_restore_test.sql) y sustituya:

- `<BACKUP_FILE>` por la ruta exacta del paso 2.
- `<DATA_LOGICAL_NAME>` por el `LogicalName` de la única fila `Type=D`.
- `<LOG_LOGICAL_NAME>` por el `LogicalName` de la única fila `Type=L`.

Ejecute el archivo completo. Usa `MOVE`, `RECOVERY`, `CHECKSUM`, `STATS=10` y deliberadamente no usa `REPLACE`.

Resultado esperado: TEST `ONLINE`, MDF `C:\Servicios IT\BasesDeDatos\MSSQL\Data\DDR001_Hidrantes_TEST.mdf` y LDF `C:\Servicios IT\BasesDeDatos\MSSQL\Data\DDR001_Hidrantes_TEST_log.ldf`.

**DETÉNGASE** si ya existe la DB, el MDF, el LDF o no existe el backup; también si logical names o cantidad de archivos no coinciden.

## PASO 5 — Conteos y CHECKDB

Ejecute [05_post_restore_validation.sql](05_post_restore_validation.sql).

Resultado esperado: cada tabla aparece con conteos PROD y TEST iguales y `difference = 0`. `DBCC CHECKDB` debe terminar sin errores.

**DETÉNGASE** si falta una tabla, hay diferencias o CHECKDB reporta cualquier error. Guarde la salida completa.

## PASO 6 — Aislar identidades y sesiones clonadas

Cambie explícitamente el selector de base de SSMS a `DDR001_Hidrantes_TEST`, abra una consulta nueva y ejecute [06_isolate_test.sql](06_isolate_test.sql).

El script no elimina filas. Revoca refresh tokens, cierra work sessions abiertas, revoca sesiones persistentes y bindings si esas tablas existen con una forma reconocida, y desactiva admins clonados. Preserva datos RV, mappings, reportes, auditoría, catálogos y triggers.

Resultado esperado: COMMIT y conteos activos finales en cero. El repositorio local no contiene DDL de `rv.persistent_field_sessions` ni `rv.device_bindings`; por ello el script valida columnas compatibles y aborta antes de escribir si encuentra una forma desconocida.

**DETÉNGASE** ante cualquier `THROW`, especialmente si informa una forma desconocida. Envíe los nombres/columnas reales; no adapte el UPDATE manualmente.

## PASO 7 — Recovery SIMPLE

Ejecute [07_recovery_simple.sql](07_recovery_simple.sql).

Resultado esperado: `DDR001_Hidrantes_Prod = FULL` y `DDR001_Hidrantes_TEST = SIMPLE`. El script aborta si PROD no era FULL y nunca la altera.

## PASO 8 — Crear login Runtime TEST

Abra [08_runtime_login.sql](08_runtime_login.sql), sustituya `<RUNTIME_PASSWORD>` localmente por una contraseña fuerte y ejecute como operador. No guarde ni comparta el archivo ya sustituido.

El código actual usa SQL directo en muchas tablas de `rv`: necesita `SELECT` sobre el esquema, `EXECUTE` sobre el esquema y DML sólo en las tablas enumeradas por el script. No recibe `db_owner`, DDL ni permisos de backup. El login sólo se mapea a TEST; no se crea usuario en PROD.

La prueba al final usa `EXECUTE AS LOGIN`: TEST debe devolver `TEST_ACCESS_OK`; intentar `USE DDR001_Hidrantes_Prod` debe caer en `CATCH` y devolver `PROD_ACCESS_DENIED_OK`.

**DETÉNGASE** si PROD resulta accesible. No inicie la API.

## PASO 9 — Crear login Migrator TEST (sin activar construction)

Abra [09_migrator_login.sql](09_migrator_login.sql), sustituya `<MIGRATOR_PASSWORD>` y ejecútelo.

Este bloque crea login/user, le permite conectar a TEST y demuestra que PROD falla. Intencionalmente no crea `construction` ni concede DDL todavía. La sección claramente rotulada `FASE POSTERIOR` queda comentada y sólo se usará después de autorización expresa y de crear el esquema de manera controlada. Así se cumple el límite actual sin entregar `db_owner` ni permisos de instancia.

## Checklist que debe reportar el operador

- [ ] Servidor exacto y versión/edición confirmados.
- [ ] Precheck OK y TEST inicialmente ausente.
- [ ] Ruta exacta del `.bak` COPY_ONLY.
- [ ] Backup y VERIFYONLY OK.
- [ ] FILELISTONLY completo (LogicalName/Type/Size y cantidad de filas).
- [ ] Restore OK y rutas físicas TEST exactas.
- [ ] Los siete pares de conteos y diferencias.
- [ ] CHECKDB OK (texto exacto del resultado).
- [ ] Aislamiento COMMIT y cinco conteos activos en cero/no aplica.
- [ ] PROD FULL y TEST SIMPLE.
- [ ] Runtime creado: TEST OK / PROD denegado.
- [ ] Migrator creado: TEST OK / PROD denegado / DDL aún no activado.
- [ ] Credenciales disponibles sólo en el gestor/local seguro (no enviarlas por chat).

## Errores que obligan a detenerse

- Servidor, instancia, edición, DB o rutas diferentes.
- TEST ya existe, o MDF/LDF/backup target ya existen.
- Permisos insuficientes, backup/VERIFYONLY/restore/CHECKDB con error.
- FILELISTONLY con estructura distinta de 1 data + 1 log.
- Cualquier diferencia de conteos.
- Tablas de aislamiento con columnas desconocidas o activos finales distintos de cero.
- Producción no está FULL o TEST no queda SIMPLE.
- Runtime o Migrator pueden abrir producción.
- Cualquier script intenta solicitar `REPLACE`, borrar filas o usar storage productivo.

## Preparación posterior de la API local (no ejecutar hasta confirmar TEST)

El repositorio `/Users/martino/DEV/ddr001_api` está actualmente en `feature/photo-sync-integrity-hardening`. Usa Node 22, `dotenv/config`, `npm run dev`, `PORT`, variables `SQL_*`, `STORAGE_ROOT` y cuatro secretos JWT/refresh. La configuración local actual señala `cifra.agrienlace.com:11333`, pero no se intentó conectar. Como existe un `.env` productivo, se debe impedir que `dotenv` lo use como fallback. La forma coherente sin cambiar código es forzar su ruta:

```sh
DOTENV_CONFIG_PATH=.env.construction-test.local npm run dev
```

Para watch, posteriormente se puede añadir un script npm explícito o usar un cargador de entorno. No se hará ahora.

Antes de crear el archivo, agregar a `.gitignore` la regla `.env.*.local` y verificar con `git check-ignore .env.construction-test.local`. Después crear localmente y no trackear `/Users/martino/DEV/ddr001_api/.env.construction-test.local` con una configuración **completa** (para no heredar producción):

```dotenv
NODE_ENV=test
PORT=3003
SQL_SERVER=cifra.agrienlace.com
SQL_PORT=11333
SQL_DATABASE=DDR001_Hidrantes_TEST
SQL_USER=DDR001_Levantamientos_TEST_Runtime
SQL_PASSWORD=<LOCAL_SECRET>
SQL_ENCRYPT=false
SQL_TRUST_SERVER_CERTIFICATE=true
FIELD_JWT_SECRET=<TEST_UNICO_MINIMO_32_CARACTERES>
FIELD_REFRESH_SECRET=<TEST_UNICO_MINIMO_32_CARACTERES>
ADMIN_JWT_SECRET=<TEST_UNICO_MINIMO_32_CARACTERES>
ADMIN_REFRESH_SECRET=<TEST_UNICO_MINIMO_32_CARACTERES>
STORAGE_ROOT=/Users/martino/DEV/ddr001_storage_test
PHOTO_INTEGRITY_JOB_ENABLED=false
PHOTO_INTEGRITY_JOB_INTERVAL_MINUTES=60
PHOTO_INTEGRITY_JOB_BATCH_SIZE=100
CORS_ORIGINS=http://localhost:3003
PUBLIC_BASE_URL=http://localhost:3003
SQL_PRODUCTION_DATABASE=DDR001_Hidrantes_Prod
```

`SQL_PRODUCTION_DATABASE` todavía no existe en el esquema Zod actual; se documenta para la guarda futura. La implementación inicial de `feature/construction-field-app` deberá:

1. declarar y validar `SQL_PRODUCTION_DATABASE`;
2. normalizar ambos nombres con `trim().toLowerCase()`;
3. antes de abrir el pool, abortar startup si `NODE_ENV !== 'production'` y `SQL_DATABASE === SQL_PRODUCTION_DATABASE`;
4. opcionalmente exigir que un entorno no productivo termine en `_TEST`;
5. tras conectar, consultar `DB_NAME()` y abortar si la DB efectiva no coincide exactamente con la configurada;
6. probar unitariamente mayúsculas/minúsculas, espacios y conexión efectiva equivocada.

La ruta propuesta de storage es `/Users/martino/DEV/ddr001_storage_test`: está fuera del repo/API, claramente marcada TEST, es eliminable sin tocar producción y permite fixtures para `missing_original`, `missing_thumbnail`, hash mismatch, reupload y orphan files. Debe crearse sólo después de confirmar TEST. Aunque esté fuera del repo, se añadirá también una regla defensiva local/documentada; nunca se usará `C:\APIS\DDR001-Hidrantes\storage`.

La DB clonada conservará `storage_path`/`thumbnail_path` históricos, pero esos archivos no están disponibles localmente. Es esperado. No se modificarán esos registros, no se copiará/descargará producción, no se marcarán masivamente como missing y no se correrá reconciliación/integrity sobre el clon completo. Las pruebas construction crearán filas/fixtures nuevos identificables en TEST y usarán únicamente el storage local. Los datos tabulares restaurados sí podrán apoyar users, hydrants, inspections, catálogos, cuentas y permisos. HTTPS externo, DNS, IIS, certificados y puertos públicos quedan pospuestos.

No se creó rama, schema construction, Flutter, directorio de storage ni configuración con secretos.
