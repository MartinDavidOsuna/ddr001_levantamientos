# HAPI-3.2 — Certificación Flutter ↔ HTTP ↔ SQL Server 2014 TEST

## 1. Dictamen y alcance

**HAPI-3.2: PASS.** Los 12 escenarios únicos T1–T12 se ejecutaron en Pixel físico con transporte Dio/HTTP real, middleware DDR001 y persistencia SQL TEST. No son resultados de mocks. El éxito acredita entrega de documentos y recuperación; **no acredita presión hidráulica ni verificación remota de fotografías**.

Se corrigió una incompatibilidad real de GUID internos de dispositivo y se repitió el envío original sin cambiar UUID ni hash. No se implementó nuevamente la sincronización. Los cambios quedan sin commit. No hubo push, merge, despliegue, migración ni acceso productivo.

## 2. Git inicial y final

| Repositorio | Rama inicial/final | HEAD inicial/final |
|---|---|---|
| móvil | feat/hydrostatic-mobile-sync | 0ae3ab0c9791584a766a80d241c4f3c9621af2ef |
| API | feat/hydrostatic-api-integration | 1181a7070b0937900704b70480e6bd5db10c59a5 |

Remotos oficiales MartinDavidOsuna/ddr001_levantamientos y MartinDavidOsuna/ddr001_api. Se mantienen los respaldos HAPI-3.1 y fix Gabinetes. No se crearon worktrees/clones, ni se cambió main. `git diff --check` sin errores.

Se preservaron cambios previos ANDROID-1: Gradle, `test/cabinets/harness.dart`, `test/cabinets/android_deletion_qa.dart`, `docs/cabinets/android-local-deletion-qa.md`, Excel e informes. La modificación Gradle nueva se añadió sobre el trabajo existente; no se incluyeron ni descartaron esos archivos en commits.

## 3. Dispositivo, paquetes y aislamiento

Pixel 7 Pro, Android 17, ADB autorizado. Serial omitido deliberadamente.

| Paquete | Versión | Android UID | Acción de esta etapa |
|---|---|---|---|
| com.aquafim.ddr001levantamientos | 1.5.24 / 35 | 10376 | Ninguna |
| com.aquafim.ddr001levantamientos.hydrotest | 1.5.18 / 29 | 10393 | Ninguna |
| com.aquafim.ddr001levantamientos.cabinettest | 1.5.24-qa.android1 / 36 | 10398 | Ninguna |
| com.aquafim.ddr001levantamientos.hydrosyncqa | 1.5.24-qa.hapi32 / 37 | 10401 | Instalación/actualizaciones QA compatibles y pruebas |

Se verificaron package, permisos y firma. Sandbox propio, sin sharedUserId, sin datos importados, allowBackup false. Sólo se cerró el proceso hydrosyncqa. No se desinstaló ni limpió almacenamiento, no se cambió el reloj Android, no se reinició el teléfono ni se alteraron permisos/sesiones de paquetes existentes. Sus fechas de actualización permanecieron intactas.

## 4. Compilación e instrumentación QA

APK: `/Users/martino/DEV/ddr001_levantamientos/build/app/outputs/flutter-apk/app-hydrosyncqa-1.5.24-37.apk`.

SHA-256: `27658318527a85ddab70b13d69c7c90445c022366528d22345cf28f18650459c`.

Certificado debug SHA-256: `294d1c1cf25490509b7e0c9643cd82d42c48faed4b449e4d1497b59a6e0ac731`.

```sh
ORG_GRADLE_PROJECT_hydrostaticSyncTest=true flutter build apk --debug --no-pub \
 -t test/hydrostatic/android_sync_qa.dart \
 --build-name=1.5.24-qa.hapi32 --build-number=37 \
 --dart-define=APP_ENV=test --dart-define=HYDROSTATIC_SYNC_ENABLED=true
```

Instalación mediante `adb -s <PIXEL> install -r <APK_QA>`, nunca sobre otro paquete. Gradle impide combinar flags QA y usar esta variante como release. Manifest y network-security independientes permiten localhost; el cliente QA rechaza hosts/puertos diferentes a 127.0.0.1:3002. No hay credenciales incorporadas en el APK.

El entrypoint usa HydrostaticRepository/Store/SyncStore/Sync/SyncApi/SyncRunner y ApiClient reales. Sólo datos, reloj e inyección de pérdida de respuesta son QA. No usa transporte simulado. La instrumentación genera PNG sintéticos de 16×16; no son fotos de una prueba física de presión.

## 5. API local TEST y conexión

SQL confirmado mediante conexión guardada: `DDR001_Hidrantes_TEST`, motor **12.0.4237.0** (SQL Server 2014). No se modificó .env ni servicios IIS/NSSM.

`scripts/hydrostatic-mobile-test-server.ts` usa createApp real y listener 127.0.0.1:3002, sin importar arranque de workers. Exige `--prepare-isolated-test`, NODE_ENV=test, HYDROSTATIC_TEST_ENABLED=true y DB TEST exacta. Rechaza sobrescribir fixtures existentes; para continuar exige `--resume-fixtures`.

Se deshabilitaron explícitamente limpieza, archivado y jobs auxiliares. PID inicial 57252; tras corregir el esquema, PID 59224. **Ambos procesos de esta etapa quedaron cerrados**. Puerto 3002 sin listener al finalizar.

ADB reverse tcp:3002 → tcp:3002 se creó tras verificar ausencia de regla ajena. Se retiró/restauró únicamente esta regla para T8/T9 y se retiró al terminar. No se abrieron firewall/IP pública. Capabilities sin sesión devolvió 401 esperado; Flutter autenticado obtuvo 200.

## 6. Identidad TEST y conservación de fixtures

Run sintético: `fc7981d4-3ed2-48e1-9b63-2b4be26b656f`.

Se crearon dos residentes sintéticos nuevos en rv.users/construction.app_users mediante transacción TEST y nombres HAPI32 SYNTHETIC. No se modificaron usuarios operativos ni empresas existentes. Datos de acceso sintéticos se pasaron al sandbox en tiempo de ejecución; Flutter realizó POST real /field-sessions/start. Middleware JWT/Field, client_app, instalación, acceso y ownership permanecieron activos. Tokens guardados sólo mediante SecureSessionStore; no se incluyen aquí.

Se registró un gabinete sintético nuevo mediante el endpoint real de Gabinetes, con UID libre comprobado y catálogo real. Las filas sintéticas, sesiones y evidencias declaradas **se conservan para auditoría**; no se elimina historial append-only. Una eventual desactivación de usuarios/limpieza exige un procedimiento posterior autorizado, acotado a este run. No se importaron expedientes anteriores del Pixel.

## 7. Matriz física T1–T12

| Caso | Resultado | Evidencia real |
|---|---|---|
| T1 Capabilities | PASS | HTTP 200, hydrostatic-sync-v1, catálogo hydrostatic-joints-v1 de 11 uniones, entorno TEST |
| T2 Registro A | PASS | POST 200, COMMITTED, documento/operación/auditoría SQL y owner coincidentes |
| T3 Replay exacto | PASS | Mismo operationId/recibo/committedAt; un único evento SQL |
| T4 Respuesta perdida | PASS | Interceptor QA descarta respuesta HTTP 200 después del COMMIT; SENT_UNKNOWN; GET recupera recibo sin segundo registro |
| T5 Actualización D | PASS | Declaración local durable posterior; UPDATE_DOCUMENT expectedVersion 1 → serverVersion 2 |
| T6 FUGA B | PASS | FAILED/LEAK, J01, 2345 milésimas de bar, fotos declaradas y pendientes |
| T7 DESCARTADA C | PASS | Política 30m, descarte conservado; resultado PENDING, no convertido en FAILED ni recalculado por receivedAt |
| T8 Sin conexión | PASS | Se quita sólo reverse QA; HTTP falla, Hive/outbox/fingerprint se conservan; SQL aún sin OFFLINE |
| T9 Reinicio QA | PASS | Proceso 13105 cerrado, nuevo 13534; reabre Hive; runner real envía operación previa tras restaurar reverse |
| T10 Identidad distinta | PASS | Segunda sesión/instalación TEST: lista vacía, view null, ningún envío del anterior; acceso remoto al ajeno 404 |
| T11 Conflicto | PASS | Otro escritor autorizado adelanta versión de preparación sintética; 409; fuente/comando intactos; OFFLINE sigue sincronizando |
| T12 Archivos | PASS | 13 originales verificados de nuevo por ADB/tamaño/SHA-256; ningún binario enviado; servidor pendiente |

T1 se repitió durante reanudaciones pero se cuenta una vez. **12 PASS, 0 FAIL final, 0 pendientes de T1–T12**. Se usó reinicio de proceso QA, no reinicio global del dispositivo. El control temporal fue inyectado únicamente en QA.

## 8. Expedientes y evidencia SQL

Consultas restringidas a los seis UUID de esta ejecución en construction.hydrostatic_tests/documents/operations/evidences/leaks/audit_events. Script de lectura: `scripts/hydrostatic-mobile-test-verify.ts`.

| Caso | UUID | Documentos | Operaciones | Auditorías | Validación remota |
|---|---|---:|---:|---:|---|
| A | `98e26174-3c5d-4977-8032-709ec39d4706` | 1 | 1 | 1 | EVIDENCE_PENDING |
| B | `0a929fc3-2969-4021-b8d1-97cb6c7f5e8f` | 1 | 1 | 1 | EVIDENCE_PENDING |
| C | `4960af95-d25d-44f2-9e74-1e30a136b2cb` | 1 | 1 | 1 | EVIDENCE_PENDING |
| D | `d31c3879-b166-4403-80b6-42c8c91d27a8` | 2 | 2 | 2 | EVIDENCE_PENDING |
| OFFLINE | `f4c3ae43-cfb6-49cd-8c6f-53d4e7eeb3ab` | 1 | 1 | 1 | EVIDENCE_PENDING |
| CONFLICT | `a00aabc9-d1db-4af4-9cb0-2776ea103094` | 2 | 2 | 2 | HISTORY_PENDING |

Total: seis intentos, ocho documentos, ocho operaciones, ocho auditorías. El escritor concurrente de CONFLICT aporta la octava operación; el comando rechazado no crea una operación comprometida. OFFLINE tenía cero filas antes de reconectar. SQL payload_sha256 se recalculó y se contrastó con sourceHash. Siete recibos del outbox local conciliados campo por campo; la operación del escritor concurrente figura separada.

| Caso | Operación | Comando | Versión | Commit UTC |
|---|---|---|---:|---|
| A | `43e340d2-aaa9-47a5-8e66-a87fa3e36e79` | REGISTER_DOCUMENT | 1 | 2026-10-29T22:33:50.468Z |
| B | `0e366bee-23cc-42e9-a6fe-32b1ec9ec7fc` | REGISTER_DOCUMENT | 1 | 2026-10-29T22:35:16.333Z |
| C | `67048c0c-d8e3-4158-b8c9-350fbeb67d82` | REGISTER_DOCUMENT | 1 | 2026-10-29T22:35:17.468Z |
| D | `c2f32f6d-2b7a-4e0c-93af-6aba55c66f05` | REGISTER_DOCUMENT | 1 | 2026-10-29T22:33:51.806Z |
| D | `17ce51d5-a7ef-4d8a-a415-281a1f524db3` | UPDATE_DOCUMENT | 2 | 2026-10-29T22:33:53.116Z |
| OFFLINE | `3cdfa58b-7056-49b6-8480-e9c5d4b26224` | REGISTER_DOCUMENT | 1 | 2026-10-29T22:38:36.750Z |
| CONFLICT | `9142efe9-d60f-42a1-b18e-5d954c9d9cb4` | REGISTER_DOCUMENT | 1 | 2026-10-29T22:37:31.250Z |
| CONFLICT | `d9677693-1680-4df7-9e8d-cb949805825d` | UPDATE_DOCUMENT | 2 | 2026-10-29T22:37:31.790Z |

## 9. Recuperación, idempotencia y archivos

Se preservó la primera operación de A rechazada por el defecto de dispositivo: mismo UUID de intento, operationId y payloadSHA tras corregir API. La recuperación T4 utiliza GET de operación; no genera nuevo comando. T9 recupera almacenamiento real desde otro proceso, no variables de widget. El conflicto conserva la fuente y no aplica last-write-wins.

Los 13 originales sintéticos conservan tamaño y SHA. Hay 12 evidencias declaradas en SQL: el original adicional pertenece al cambio local rechazado por conflicto. Servidor conserva server_sha256 null, integrity UNKNOWN, upload DECLARED y storageObject null. Recibir un documento no verifica un archivo. No se enviaron bytes fotográficos, video, mensajes WhatsApp ni datos a NAS.

## 10. Defecto real y corrección

Primer REGISTER_DOCUMENT: HTTP 422 por deviceId/originDeviceId. `rv.devices.device_id` genera GUID secuenciales con NEWSEQUENTIALID(); el esquema interno exigía UUIDv4. La autenticación y capabilities ya funcionaban, por eso el fallo se manifestaba al registrar.

Corrección acotada en API `src/modules/hydrostatic/schemas.ts:209`: sqlDeviceId acepta GUID válido canónico minúsculo para los dos identificadores internos resueltos desde SQL. No se altera UUIDv4 del contrato de intentos, operaciones o instalación; no se relaja autorización. `tests/unit/hydrostatic-domain.test.ts` añade dos regresiones de GUID secuencial válido y rechazos de identidad/permiso/UUID cliente inválidos.

Después de corregir y reiniciar sólo nuestra API, la operación original fue aceptada. Las pruebas físicas y regresión final pasaron.

## 11. Incidencias intermedias

- Compilación inicial QA refería discarded como enum; se corrigió la instrumentación para usar la dimensión real de descarte.
- Conflicto manifest networkSecurityConfig resuelto mediante override limitado al source set QA.
- Fixture de borrador de fuga incompleto causó INVALID_DRAFT; se añadió versión/observación/descripción requeridas, sin debilitar dominio y continuando el UUID existente.
- Intento inicial de escritor concurrente sobre PASSED recibió TERMINAL_IMMUTABLE correctamente; se pasó el escenario de conflicto a una preparación independiente. No se cambió la inmutabilidad backend.
- Una utilidad inicial sin opt-in TEST se negó a ejecutar; se utilizó la comprobación guardada correspondiente.
- Advertencia preexistente de plugin Kotlin flutter_image_compress_common durante build; no se actualizaron dependencias.

Los fallos intermedios no se ocultan ni se cuentan como PASS; fueron corregidos en instrumentación o, para el GUID, en API y después repetidos.

## 12. Regresión

| Validación | PASS | FAIL | Omitidas |
|---|---:|---:|---:|
| Flutter suite completa segura | 741 | 0 | 1 |
| API suite general segura | 1233 | 0 | 162 |
| Android HTTP/SQL T1–T12 únicos | 12 | 0 | 0 |

Flutter analyze: sin issues. API lint, type-check y build: PASS. Formato y diff-check: PASS. Pruebas específicas hidrostáticas, outbox, cámara, Gabinetes, autorización y persistencia incluidas en la suite; no se suman otra vez. API incluye dos nuevas pruebas del defecto. La prueba Flutter omitida requiere CABINETS_TEST_SESSION; las 162 API son integraciones opt-in externas/SQL deshabilitadas en la regresión general segura. Eso no sustituye la certificación HTTP/SQL real de esta etapa. No se obtuvo nueva métrica de cobertura. No se cambiaron expectativas para ocultar fallos.

## 13. Archivos modificados y preservación

Móvil: android/app/build.gradle.kts (extensión sobre ANDROID-1), nuevo android/app/src/hydrostaticSyncTest/AndroidManifest.xml, res/xml/hydrosync_network.xml y test/hydrostatic/android_sync_qa.dart. API: schemas.ts, prueba unit, scripts hydrostatic-mobile-test-server.ts y hydrostatic-mobile-test-verify.ts. Informes/evidencias quedan sin seguimiento. No se modificó código funcional móvil de sincronización, API de Gabinetes, SQL schema ni Dashboard.

## 14. Reproducción acotada

1. Verificar ramas, cambios y package del Pixel. No usar paquetes operativos.
2. Configuración SQL existente más NODE_ENV=test, SQL_DATABASE=DDR001_Hidrantes_TEST, HYDROSTATIC_TEST_ENABLED=true, PORT=3002. Deshabilitar jobs/archiver. Ejecutar runner con --prepare-isolated-test; usar --resume-fixtures para manifiesto previo. Nunca sobrescribirlo.
3. Crear reverse libre tcp:3002. Compilar con comando de sección 4, comprobar package/firma/versionCode y actualizar sólo hydrosyncqa.
4. Pasar `/tmp/hapi32-fixtures.json` al archivo privado files/hapi32-fixtures.json por stdin de `run-as` del paquete QA. No incorporar el manifiesto ni credenciales al APK.
5. Abrir QA y ejecutar primera fase. Quitar exclusivamente reverse QA antes de PRUEBA SIN RED. Cerrar sólo QA, restaurar reverse, abrir y ejecutar recuperación. La UI guarda resultados y traza en files/hapi32-state.json.
6. Exportar únicamente ese estado sintético y ejecutar `NODE_ENV=test SQL_DATABASE=DDR001_Hidrantes_TEST node_modules/.bin/tsx scripts/hydrostatic-mobile-test-verify.ts <estado.json> --final` desde API. Verificar hashes de originales QA.
7. Retirar reverse propio y terminar exclusivamente PID del runner. Conservar fixtures y evidencia; no limpiar bases ni almacenamiento.

Esta instrumentación continúa el run existente de forma idempotente. Una certificación completamente nueva requiere elegir explícitamente nuevos fixtures/nombres, sin borrar el run anterior.

## 15. Riesgos y pendientes HAPI-4

- Upload/archivo/verificación física de evidencias, segmentos de historial y validación hidráulica remota siguen deshabilitados por capabilities. Entrega de documento no significa expediente remoto validado.
- Los usuarios fuente sintéticos usan UUIDv4. La compatibilidad con otros GUID históricos en actor/session/cabinet no se certificó aquí; revisar antes de ampliar a identidades legacy. La corrección ejecutada cubre los IDs internos de dispositivo realmente fallidos.
- No se certificó transporte fuera de ADB reverse, TLS desplegado, redes móviles, NAS ni producción.
- QA usa imágenes y coordenadas sintéticas; no demuestra cámara/GPS ni presión real en esta etapa.
- La APK debug/instrumentación no es un artefacto productivo. No distribuir ni integrar automáticamente.
- Instancia TEST cerrada al terminar: para una revisión posterior habrá que arrancarla explícitamente. Datos sintéticos SQL y sandbox permanecen intactos.

## 16. Evidencias conservadas

Carpeta adyacente `HAPI-3.2_2026-10-29_15-48-43_evidencias`: SQL.json (recibos y filas sanitizadas), HTTP.json (traza sin tokens), originales-SHA256.json, conciliacion.json y logs de regresión. No se copian fotografías privadas, tokens, serial completo ni coordenadas reales. Los hashes corresponden exclusivamente a imágenes generadas para TEST.

## 17. Estado final

**PASS en el alcance HAPI-3.2:** certificación física de sincronización documental real, fallo de integración corregido y regresiones satisfactorias. No autoriza despliegue productivo ni adelanta HAPI-4. Datos operativos preservados; cambios nuevos sin commit; sin push/merge.

## 18. Apertura del informe

Archivo verificado existente. VS Code abierto mediante `code -r`; comando terminado con código 0.
