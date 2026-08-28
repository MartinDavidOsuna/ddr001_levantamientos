# Plan técnico del primer build — DDR001 Levantamientos

Alcance de esta entrega: análisis y planificación únicamente. No se modificaron archivos, no se creó el proyecto Flutter, no se ejecutó SQL de escritura, no se crearon ramas, migraciones, commits, tablas, backups ni restores.

## 1. Baselines inspeccionados

### API DDR001

| Elemento | Resultado |
|---|---|
| Repositorio | `MartinDavidOsuna/ddr001_api` |
| Worktree | `/Users/martino/DEV/ddr001_api` |
| Rama activa | `feature/photo-sync-integrity-hardening` |
| SHA baseline | `54c76daa84d78c2f370de366a5f058cd0794bdf7` |
| Fecha | 2026-08-26 15:06:03 -06:00 |
| `main` | `85265fda09046dd47ce0e5e0f614f013ae9c35e4` |
| Relación | Hardened está 2 commits adelante y 0 atrás de `main` |
| Merge-base | `85265fda09046dd47ce0e5e0f614f013ae9c35e4` |
| Estado | Worktree limpio |
| Remoto | La rama hardened sí existe en `origin` |
| Stack | Node 22, TypeScript, Express, Zod, `mssql`, Sharp, Multer, Pino, Vitest |
| DB configurada localmente | `DDR001_Hidrantes_Prod` |
| Storage productivo configurado | `C:\APIS\DDR001-Hidrantes\storage` |

Se ejecutó `git fetch --all --prune`. El contrato fotográfico real confirma exactamente estos estados:

`confirmed`, `missing_original`, `missing_thumbnail`, `hash_mismatch`, `missing_mapping`, `mapping_conflict`, `deleted`, `not_verified`, `not_found`.

### App DDR001 RV

| Elemento | Resultado |
|---|---|
| Repositorio | `MartinDavidOsuna/ddr001_diag_rv_app` |
| Worktree | `/Users/martino/DEV/ddr001_diag_rv_app` |
| Rama activa | `feature/photo-sync-integrity-hardening` |
| SHA baseline | `e6b7438fd48d8b3b38d10bf520ffc8ceb3f5b7b4` |
| Fecha | 2026-08-26 15:20:40 -06:00 |
| `main` | `c01961d65f5cc0fc0275b13c83cc1f2c98014789` |
| Relación | Hardened está 22 commits adelante y 0 atrás de `main` |
| Estado | Worktree limpio |
| Observación crítica | Tras `fetch --all --prune`, la rama hardened ya no existe en `origin`; el baseline es una rama local no publicada |
| Flutter | 3.44.8 stable |
| Dart | 3.12.2 |
| Proyecto actual | `ddr001diag` |
| Versión declarada | `1.0.1+101` |
| Android applicationId | `com.aquafim.ddr001diag` |
| iOS bundle ID | `com.aquafim.ddr001diag` |
| iOS mínimo | 13.0 |

### App de verificación funcional

Se inspeccionó el remoto mediante clon temporal, sin modificar ningún repositorio de trabajo.

| Rama | SHA | Relación |
|---|---|---|
| `feature/stage-1-metrology-engine` | `f904c1a57d3d707f56bb7436b6388ede605ab0a6` | Inicio |
| `feature/stage-2-offline-domain` | `bd2ebb53e96ae58460def2eba2338db95a43e17b` | Descendiente de stage 1 |
| `feature/stage-3-flutter-ui` | `b5d24a5d3027dc4932cf9e92adfd33c44dd20da4` | Descendiente de stage 2 |
| `feature/stage-4-visual-reading-camera` | `fd7b9772b79716e716d03ea59954b1dbcf98c88b` | Descendiente de stage 3; coincide con `master` |
| `feature/stage-5-esp32-pulse-sources` | `a51774a0dadeceebb480a073b79be952e3f64bd6` | Descendiente de stage 4; versión funcional más reciente |

Conclusión: `feature/stage-5-esp32-pulse-sources` contiene también las mejoras de UI/perfil de las etapas anteriores. Se tomará esa rama como referencia visual, excluyendo el dominio metrológico/ESP32.

### Repositorio nuevo

| Elemento | Resultado |
|---|---|
| Remoto | `MartinDavidOsuna/ddr001_levantamientos` |
| Heads remotos | Ninguno; repositorio realmente vacío |
| Directorio local | `/Users/martino/DEV/ddr001_levantamientos` |
| Estado local | Vacío, sin `.git`, sin proyecto Flutter |
| Decisión | Será el único repositorio de la nueva app |

### Base de datos real inspeccionada

Consulta exclusivamente read-only:

| Elemento | Resultado |
|---|---|
| SQL Server | `WIN-5RQE8N8NQ9V` |
| Versión | SQL Server 2014, `12.0.4237.0 SP1` |
| Edición | Standard 64-bit |
| Producción real | `DDR001_Hidrantes_Prod` |
| Recovery | `FULL` |
| Tamaño | 116.0625 MB |
| MDF lógico | `DDR001_Hidrantes_Prod`, 111 MB |
| LDF lógico | `DDR001_Hidrantes_Prod_log`, 5.0625 MB |
| Cuenta API | `sysadmin`; riesgo alto, debe reemplazarse para test/runtime |
| Backups visibles en `msdb` | Ninguno para esta DB |
| Jobs de instancia | Cuatro jobs habilitados; ninguno tiene nombre DDR001, pero deben auditarse por contenido antes del restore |
| Schema construction | No existe |
| Volumen relevante | 1,254 hidrantes; 650 inspecciones; 6,079 fotos; 22 usuarios de campo |

## 2. Arquitectura reutilizable encontrada

### Auth y sesión

Origen RV:

- `lib/features/auth/data/field_session_repository.dart`
- `lib/features/auth/data/field_session_models.dart`
- `lib/features/auth/data/session_secure_storage.dart`
- `lib/features/auth/auth_pages.dart`
- `lib/core/network/api_client.dart`

Origen API:

- `src/modules/api.routes.ts`
- `src/modules/auth/refresh.service.ts`
- `src/security/jwt.ts`
- `docs/field-session-lifecycle.md`

Contrato vigente:

- `POST /api/v1/field-sessions/start`
- `POST /api/v1/field-sessions/revoke-existing`
- `GET /api/v1/field-sessions/current`
- `POST /api/v1/field-sessions/refresh`
- `POST /api/v1/field-sessions/:id/end`

Login real: nombre, correo, teléfono de 10 dígitos, cuadrilla y metadata del dispositivo. Incluye `installationId`, tokens rotatorios, takeover y sesión persistente offline.

### Persistencia

RV utiliza:

- Hive CE para documentos, colas, fotos, journal y cachés.
- Secure Storage para tokens, identidad de sesión e `installationId`.
- SharedPreferences para preferencias/UI/configuración no sensible.
- Documentos JSON versionados y repositorios explícitos.
- Operation journal y recuperación de operaciones incompletas.

La nueva app debe conservar este patrón, pero con boxes y DTOs exclusivos de construction.

### Sincronización

Patrones maduros encontrados:

- colas persistentes separadas para dominio y media;
- UUID estable;
- `Idempotency-Key`;
- retry sólo para operaciones seguras o explícitamente idempotentes;
- single-flight para refresh;
- backoff y registro de intentos;
- reconciliación al arranque;
- preservación del trabajo si refresh falla por red/5xx;
- borrado de credenciales sólo ante revocación definitiva;
- merge local/server por UUID.

### Fotografías

Componentes relevantes:

- `ReliablePhotoService`
- `StreamingFileDigestService`
- `MediaReconciliationService`
- `ThumbnailRegenerationService`
- `OperationJournalRepository`
- `OrphanMediaScanner`
- `InspectionPhoto`
- `MediaSyncStatus`
- `PhotoIntegrityStatus`
- `inspection_sync_coordinator.dart`

El cliente actual ya distingue upload de confirmación definitiva. `InspectionPhoto.isSynchronized` depende de `integrityStatus.confirmed`, no de un booleano.

### GPS

RV usa `geolocator` y encapsula permisos/ubicación en:

- `lib/features/map/map_location_provider.dart`
- servicios de captura y modelos de fotografía con latitude, longitude y horizontal accuracy.

Debe añadirse altitude y una política explícita de posición reciente.

### Mapa

Origen:

- `lib/features/map/map_page.dart`
- `hydrant_map_marker_source.dart`
- `hydrant_spatial_index.dart`
- `map_location_provider.dart`
- pruebas en `test/map/hydrant_map_experience_test.dart`

Características existentes:

- `flutter_map`;
- tiles CARTO/OSM;
- caché/local-first de marcadores;
- búsqueda por región visible;
- debounce;
- generación de petición para descartar respuestas obsoletas;
- filtros;
- selección/callout;
- navegación al detalle;
- ubicación actual;
- carga regional sin N endpoints por marcador.

Los tiles base requieren Internet. No existe un sistema real de mapas base offline.

### Perfil

RV aporta:

- nombre, rol técnico actual y cuadrilla;
- estado de conectividad;
- métricas de enviados, pendientes y no sincronizados;
- acceso a sincronización;
- logout;
- versión;
- manual;
- diagnóstico técnico y auditoría local condicionados por rol.

Verification app aporta:

- nombre, correo y teléfono;
- ID de dispositivo;
- versión Android;
- marca y modelo;
- versión de app;
- presentación más limpia mediante filas label/value;
- manual y logout.

### Logging y errores

API:

- Pino/Pino HTTP;
- request ID;
- auditoría `rv.audit_log`;
- Problem Details y códigos de dominio;
- validación Zod;
- retry SQL ante deadlock.

Flutter:

- `ApiException` y mapeo de errores;
- request IDs;
- sanitización de UUID/tokens en diagnósticos;
- trazas locales;
- métricas de rendimiento de foto;
- estado de conectividad.

### API

La API está organizada por módulos pero concentra varias rutas antiguas en `api.routes.ts`. Construction debe nacer como módulo independiente, sin seguir aumentando ese archivo.

## 3. Componentes que NO deben reutilizarse

No se copiarán:

- modelos `rv.inspections`, checklist RV y visual reports;
- DTOs que exijan `hydrantId` o `inspectionId`;
- `visual_report_versions` y `visual_report_version_photos`;
- pantallas del checklist RV;
- medidores, metrología, MPE, pulsos, BLE, ESP32;
- OCR, detección de aguja, lectura visual;
- instrumentos, válvulas, alarmas y pruebas funcionales;
- diagnóstico celular especializado;
- importadores Excel de hidrantes;
- actualización manual de APK salvo decisión posterior;
- exportación técnica avanzada visible al contratista;
- assets/icono RV como identidad final;
- IDs Android/iOS existentes;
- el gran `AppState` de RV como bloque monolítico;
- la posibilidad `PhotoSource.deviceLibrary`;
- reglas RV de mappings a versiones visuales.

## 4. Estrategia de creación del proyecto Flutter desde cero

### Identidad propuesta

| Elemento | Propuesta |
|---|---|
| Nombre técnico Dart | `ddr001_levantamientos` |
| Nombre visible | `DDR001 Levantamientos` |
| Organization | `com.aquafim` |
| Android applicationId producción | `com.aquafim.ddr001levantamientos` |
| iOS bundle ID producción | `com.aquafim.ddr001levantamientos` |
| Versión inicial | `0.1.0+1` |
| Rama app | `feature/construction-field-app` |
| Plataformas iniciales | Android e iOS |
| Plataforma de certificación Build 1 | Android físico |
| Android mínimo propuesto | API 26 |
| iOS mínimo propuesto | iOS 13 |

Comando futuro, desde el repositorio ya clonado y vacío:

```bash
flutter create \
  --org com.aquafim \
  --project-name ddr001_levantamientos \
  --platforms android,ios \
  .
```

El identificador generado se ajustará inmediatamente a `com.aquafim.ddr001levantamientos`; no se conservará el identificador con underscore como ID comercial.

### Environments

Tres flavors:

- `dev`: sufijo `.dev`;
- `test`: sufijo `.test`;
- `prod`: sin sufijo.

Configuración por `--dart-define`/`--dart-define-from-file`:

- `APP_ENV`;
- `API_BASE_URL`;
- `GIT_SHA`;
- `BUILD_DATE_UTC`.

Los archivos con URLs no secretas podrán versionarse como ejemplos. JWT, passwords SQL, signing keys y credenciales nunca entran al bundle ni al repositorio. La app no necesita secretos para hablar con la API.

### Estructura propuesta

```text
lib/
  app/
    bootstrap/
    config/
    navigation/
    theme/
  core/
    auth/
    connectivity/
    errors/
    http/
    logging/
    persistence/
    sync/
    media/
    location/
    widgets/
  features/
    home/
    surveys/
      domain/
      data/local/
      data/remote/
      application/
      presentation/
    corrections/
    map/
    profile/
    resident/
  main.dart
  main_dev.dart
  main_test.dart
  main_prod.dart
```

Otros directorios:

```text
assets/branding/
assets/icons/
assets/config/
docs/ssot/
plans/
test/
integration_test/
tool/
```

### Archivos generados a conservar

- Android/iOS completos;
- `pubspec.yaml`, `pubspec.lock`;
- `analysis_options.yaml`;
- `.metadata`;
- `.gitignore`;
- tests base adaptados;
- configuraciones Gradle/Xcode.

Se eliminará sólo el contador demo generado.

### Lints y CI

- `flutter_lints`;
- reglas adicionales: evitar `dynamic` injustificado, imports relativos inconsistentes, futures sin await y logging con datos sensibles;
- `dart format --set-exit-if-changed`;
- `flutter analyze`;
- `flutter test`;
- tests Android de integración en pipeline separado;
- build de APK `test` sin firma productiva en CI;
- GitHub Actions con Flutter fijado explícitamente, no “latest”.

### Assets e iconografía

Validación cerrada el 2026-08-27: se reutiliza la identidad institucional Aquafim ya aprobada y utilizada por DDR001 Diagnóstico Hidrantes. El launcher compartido no contiene texto ni elementos de diagnóstico, revisión visual o metrología; también se reutilizan sus variantes Android/iOS, logotipo y símbolo institucional. No se incorporan assets funcionales específicos de RV y no quedan placeholders Flutter en el release.

### SSOT futuro

Después de autorización:

- `/plans/BASE_CONSTRUCTION_APP_PLAN.md`
- `/docs/ssot/PROJECT_TRUTH.md`
- `/docs/ssot/FUNCTIONAL_SPEC.md`
- `/docs/ssot/DATA_MODEL.md`
- `/docs/ssot/API_CONTRACT.md`
- `/docs/ssot/SYNC_MODEL.md`
- `/docs/ssot/PHOTO_INTEGRITY.md`
- `/docs/ssot/ROLES_PERMISSIONS.md`

## 5. Estrategia de reutilización selectiva

| Componente | Origen | Acción | Dependencias | Riesgo |
|---|---|---|---|---|
| Contrato login | RV/API hardened | Adaptar casi literal | Dio, device info | Bajo |
| Session repository | RV | Extraer y renombrar limpio | Secure Storage | Bajo |
| installationId | RV | Adaptar literal | UUID, Secure Storage | Bajo |
| HTTP client | RV | Reescribir limpio conservando interceptores | Dio | Medio |
| Refresh single-flight | RV | Adaptar | Auth storage | Bajo |
| Takeover | RV/API | Adaptar | API field session | Bajo |
| Hive document pattern | RV | Reimplementar por dominio | Hive CE | Medio |
| Operation journal | RV | Extraer genérico | Hive | Medio |
| Cola de sync | RV | Adaptar por command types | Hive/connectivity | Medio |
| Photo states/DTO | RV hardened | Extraer y generalizar | crypto/filesystem | Bajo |
| Procesamiento foto | RV | Adaptar camera-only | image_picker/compress | Medio |
| Verify-batch policy | RV/API | Reutilizar contrato, nuevo adapter construction | Dio/API | Medio |
| Reconciliación | RV | Adaptar sin tipos RV | Hive/files | Medio |
| GPS | RV | Adaptar con cache TTL/accuracy | geolocator | Medio |
| Mapa | RV | Adaptar arquitectura, no modelos | flutter_map | Medio |
| Spatial index | RV | Copiar/adaptar | latlong2 | Bajo |
| Perfil RV | RV | Adaptar layout/datos | session/app state | Bajo |
| Perfil mejorado | Verification stage 5 | Reusar presentación label/value | device/package info | Bajo |
| Error mapping | RV | Extraer limpio | Dio | Bajo |
| Logging | RV/API | Adaptar con redacción | Pino/debug logs | Bajo |
| Storage Sharp | API | Generalizar función existente | Sharp/fs | Alto |
| Integrity engine | API | Extraer núcleo multidominio | SQL/fs/audit | Alto |
| Idempotency middleware | API | Reutilizar directamente | `rv.idempotency_keys` | Bajo |

## 6. Modelo de roles

### Identidad

`rv.users` continúa siendo la identidad de usuario de campo. No se duplica nombre, email, teléfono ni autenticación.

Nueva relación:

```text
rv.users.user_id
        1
        |
        1
construction.app_users.user_id
```

`construction.app_users` contiene exclusivamente autorización funcional de Levantamientos.

### Reglas

- Al primer acceso a `/construction/me`, se crea idempotentemente el registro con `role='contractor'`.
- Una asignación `resident` existente nunca se degrada al iniciar sesión.
- `field` sigue siendo el tipo de token, no un rol de construction.
- `admin/supervisor/viewer` de `rv.admin_users` no se interpretan como contractor/resident.
- La promoción a resident requiere acción administrativa explícita y auditada.
- `is_active=0` bloquea sólo el acceso construction, sin desactivar `rv.users`.

## 7. Modelo de datos SQL exacto propuesto

Todos los nombres usan schema `construction`. Compatible con SQL Server 2014.

### `construction.app_users`

| Columna | Tipo | Regla |
|---|---|---|
| `user_id` | `UNIQUEIDENTIFIER` | PK y FK `rv.users(user_id)` |
| `role` | `VARCHAR(20)` | NOT NULL, `contractor/resident` |
| `is_active` | `BIT` | NOT NULL default 1 |
| `assigned_by_user_id` | `UNIQUEIDENTIFIER` | nullable, FK `rv.users` |
| `assigned_at` | `DATETIME2(3)` | NOT NULL default UTC |
| `created_at` | `DATETIME2(3)` | NOT NULL default UTC |
| `updated_at` | `DATETIME2(3)` | NOT NULL default UTC |
| `row_version` | `ROWVERSION` | NOT NULL |

Constraints:

- `CK_construction_app_users_role`.
- Sin FK hacia `rv.admin_users`.
- Índice `IX_construction_app_users_role_active(role,is_active)`.

### `construction.base_surveys`

| Columna | Tipo | Regla |
|---|---|---|
| `survey_id` | `UNIQUEIDENTIFIER` | PK; UUID móvil, sin default |
| `contractor_user_id` | `UNIQUEIDENTIFIER` | NOT NULL FK `rv.users` |
| `contractor_name_snapshot` | `NVARCHAR(180)` | NOT NULL |
| `contractor_crew_snapshot` | `NVARCHAR(120)` | nullable |
| `display_identifier` | `NVARCHAR(160)` | NOT NULL |
| `normalized_display_identifier` | `NVARCHAR(160)` | NOT NULL |
| `account_number` | `NVARCHAR(50)` | nullable |
| `normalized_account_number` | `NVARCHAR(50)` | nullable |
| `account_conflict` | `BIT` | NOT NULL default 0 |
| `conflicting_hydrant_id` | `UNIQUEIDENTIFIER` | nullable FK `rv.hydrants` |
| `status` | `VARCHAR(20)` | NOT NULL |
| `current_step_no` | `TINYINT` | NOT NULL default 0 |
| `canonical_latitude` | `DECIMAL(10,7)` | nullable |
| `canonical_longitude` | `DECIMAL(10,7)` | nullable |
| `canonical_accuracy_m` | `DECIMAL(8,2)` | nullable |
| `canonical_altitude_m` | `DECIMAL(9,2)` | nullable |
| `canonical_location_at` | `DATETIME2(3)` | nullable |
| `canonical_location_source` | `VARCHAR(30)` | nullable |
| `created_at_client` | `DATETIME2(3)` | NOT NULL |
| `created_at_server` | `DATETIME2(3)` | NOT NULL default UTC |
| `updated_at_server` | `DATETIME2(3)` | NOT NULL default UTC |
| `executed_at` | `DATETIME2(3)` | nullable |
| `accepted_at` | `DATETIME2(3)` | nullable |
| `delivered_at` | `DATETIME2(3)` | nullable |
| `last_activity_at` | `DATETIME2(3)` | NOT NULL |
| `row_version` | `ROWVERSION` | NOT NULL |

Constraints:

- status: `created`, `in_progress`, `executed`, `rejected`, `accepted`, `delivered`;
- current step `0..6`;
- latitude/longitude válidas;
- canonical lat/lng ambas null o ambas no null;
- `display_identifier` no puede quedar vacío después de trim;
- conflicto consistente: si `conflicting_hydrant_id` existe, `account_conflict=1`;
- no `UNIQUE` sobre display identifier;
- no `UNIQUE` propio sobre account number.

Índices:

- `IX_base_surveys_contractor_status_activity(contractor_user_id,status,last_activity_at DESC)`;
- `IX_base_surveys_contractor_identifier(contractor_user_id,normalized_display_identifier)`;
- `IX_base_surveys_account(normalized_account_number)`;
- `IX_base_surveys_map(status,canonical_latitude,canonical_longitude) INCLUDE (...)`;
- `IX_base_surveys_updated(updated_at_server,survey_id)` para sync incremental.

### `construction.base_survey_steps`

| Columna | Tipo | Regla |
|---|---|---|
| `step_id` | `UNIQUEIDENTIFIER` | PK; UUID móvil |
| `survey_id` | `UNIQUEIDENTIFIER` | NOT NULL FK cascade restringido |
| `step_no` | `TINYINT` | NOT NULL, 0–6 |
| `step_code` | `VARCHAR(30)` | NOT NULL |
| `comment` | `NVARCHAR(1000)` | nullable |
| `status` | `VARCHAR(20)` | `locked/open/finalized` |
| `opened_at_client` | `DATETIME2(3)` | nullable |
| `finalized_at_client` | `DATETIME2(3)` | nullable |
| `finalized_at_server` | `DATETIME2(3)` | nullable |
| `created_at_server` | `DATETIME2(3)` | default UTC |
| `updated_at_server` | `DATETIME2(3)` | default UTC |
| `row_version` | `ROWVERSION` | NOT NULL |

Códigos exactos:

- 0 `creation`;
- 1 `ground_preparation`;
- 2 `formwork`;
- 3 `reinforcement`;
- 4 `concrete_pour`;
- 5 `formwork_removal`;
- 6 `finished`.

Constraints/índices:

- `UQ_base_survey_steps_survey_no(survey_id,step_no)`;
- `UQ_base_survey_steps_survey_step(survey_id,step_id)` para FK compuesta;
- check que número y código correspondan;
- step 0 se crea finalizado junto al survey;
- sólo un step `open`, mediante índice filtrado `WHERE status='open'`.

### `construction.base_survey_corrections`

| Columna | Tipo | Regla |
|---|---|---|
| `correction_id` | `UNIQUEIDENTIFIER` | PK; UUID estable |
| `survey_id` | `UNIQUEIDENTIFIER` | NOT NULL FK |
| `round_no` | `INT` | NOT NULL, >=1 |
| `rejection_reason` | `NVARCHAR(2000)` | NOT NULL |
| `rejected_by_user_id` | `UNIQUEIDENTIFIER` | NOT NULL FK `rv.users` |
| `rejected_at` | `DATETIME2(3)` | NOT NULL |
| `comment` | `NVARCHAR(1000)` | nullable |
| `status` | `VARCHAR(20)` | `open/finalized/superseded` |
| `finalized_at_client` | `DATETIME2(3)` | nullable |
| `finalized_at_server` | `DATETIME2(3)` | nullable |
| `created_at_server` | `DATETIME2(3)` | default UTC |
| `updated_at_server` | `DATETIME2(3)` | default UTC |
| `row_version` | `ROWVERSION` | NOT NULL |

Constraints:

- unique `(survey_id,round_no)`;
- unique `(survey_id,correction_id)`;
- una sola corrección abierta por survey mediante índice filtrado;
- rejection reason trim no vacío.

### `construction.base_survey_photos`

| Columna | Tipo |
|---|---|
| `photo_id` | `UNIQUEIDENTIFIER` PK, UUID móvil |
| `survey_id` | `UNIQUEIDENTIFIER` NOT NULL |
| `step_id` | `UNIQUEIDENTIFIER` nullable |
| `correction_id` | `UNIQUEIDENTIFIER` nullable |
| `sequence_no` | `INT` NOT NULL |
| `original_filename` | `NVARCHAR(260)` nullable |
| `mime_type` | `NVARCHAR(100)` NOT NULL |
| `byte_size` | `BIGINT` NOT NULL |
| `width_px`, `height_px` | `INT` nullable |
| `client_sha256` | `CHAR(64)` NOT NULL |
| `server_sha256` | `CHAR(64)` nullable |
| `storage_path`, `thumbnail_path` | `NVARCHAR(700)` nullable |
| `upload_status` | `VARCHAR(30)` NOT NULL |
| `integrity_status` | `VARCHAR(30)` NOT NULL default `not_verified` |
| `mapping_status` | `VARCHAR(30)` NOT NULL default `missing` |
| `captured_at` | `DATETIME2(3)` NOT NULL |
| `latitude` | `DECIMAL(10,7)` NOT NULL |
| `longitude` | `DECIMAL(10,7)` NOT NULL |
| `horizontal_accuracy_m` | `DECIMAL(8,2)` nullable |
| `altitude_m` | `DECIMAL(9,2)` nullable |
| `location_captured_at` | `DATETIME2(3)` NOT NULL |
| `metadata_json` | `NVARCHAR(MAX)` nullable |
| `uploaded_at`, `verified_at`, `deleted_at` | `DATETIME2(3)` nullable |
| `integrity_checked_at`, `storage_verified_at` | `DATETIME2(3)` nullable |
| `integrity_detail_json` | `NVARCHAR(MAX)` nullable |
| `created_at_server`, `updated_at_server` | `DATETIME2(3)` NOT NULL |
| `row_version` | `ROWVERSION` |

Constraints:

- exactamente uno de `step_id` o `correction_id`;
- FK compuesta `(survey_id,step_id)` → steps;
- FK compuesta `(survey_id,correction_id)` → corrections;
- unique filtrado `(step_id,sequence_no)` y `(correction_id,sequence_no)`;
- byte size `1..MAX_UPLOAD_BYTES`;
- hashes hex de 64 caracteres;
- coordenadas válidas;
- upload status: `received/processing/verified/rejected/missing/deleted`;
- integrity status exactamente igual al contrato hardened;
- mapping status: `mapped/missing/conflict/not_applicable`;
- ninguna foto huérfana.

Para construction, `mapped` significa asociación inequívoca con step o correction, no visual report.

### `construction.base_survey_status_history`

| Columna | Tipo |
|---|---|
| `history_id` | `BIGINT IDENTITY` PK |
| `survey_id` | `UNIQUEIDENTIFIER` FK |
| `old_status`, `new_status` | `VARCHAR(20)` |
| `actor_user_id` | `UNIQUEIDENTIFIER` nullable FK `rv.users` |
| `actor_role` | `VARCHAR(20)` |
| `reason` | `NVARCHAR(2000)` nullable |
| `correction_id` | `UNIQUEIDENTIFIER` nullable FK |
| `occurred_at` | `DATETIME2(3)` default UTC |
| `request_id` | `UNIQUEIDENTIFIER` nullable |
| `metadata_json` | `NVARCHAR(MAX)` nullable |

Índice `(survey_id,occurred_at DESC)`.

### `construction.hydrant_installations`

No se creará en la primera migración salvo que se apruebe sólo un stub documental. Recomendación: definirla en SSOT, no crear una tabla vacía hasta iniciar esa fase.

## 8. Máquina de estados

### Survey

```text
CREATED
   ↓ abrir paso 1
IN_PROGRESS
   ↓ finalizar pasos 1–6
EXECUTED
   ├─ aceptar → ACCEPTED → DELIVERED
   └─ rechazar → REJECTED
                    ↓ finalizar corrección N
                 EXECUTED
```

Transiciones permitidas:

- `created → in_progress`: contractor;
- `in_progress → executed`: contractor, sólo después de paso 6;
- `executed → rejected`: resident, reason obligatorio;
- `executed → accepted`: resident;
- `accepted → delivered`: resident/operación autorizada futura;
- `rejected → executed`: contractor, al finalizar corrección abierta.

No hay transición contractor hacia accepted/delivered.

### Steps

- Step 0 se crea `finalized`.
- Sólo el siguiente paso secuencial puede abrirse.
- `locked → open → finalized`.
- No existe `finalized → open`.
- Pasos 1–5: 1 a 4 fotos activas.
- Paso 6: mínimo 4, sin máximo de dominio.
- API aplica un máximo técnico de request y paginación, no de evidencia del paso 6.

### Correcciones

- El rechazo crea correction round N en `open`.
- Mínimo una foto con ubicación.
- Sin máximo funcional.
- `open → finalized`.
- Una nueva revisión rechazada crea N+1; nunca modifica N.

## 9. Reglas de inmutabilidad y permisos

| Acción | Contractor | Resident |
|---|---:|---:|
| Crear survey propio | Sí | No en Build 1 |
| Ver propios | Sí | Sí, universo autorizado |
| Editar identifier después de crear | No | Sí |
| Editar account number | No | Sí |
| Agregar/eliminar foto en step abierto | Sí | No |
| Editar comentario en step abierto | Sí | No |
| Modificar step finalizado | No | No |
| Finalizar etapa propia | Sí | No |
| Ejecutar survey | Sí | No |
| Aceptar/rechazar | No | Sí |
| Crear evidencia de corrección | Sí, si es suyo | No |
| Editar evidencia histórica | No | No |
| Cambiar timestamps/GPS/hash | No | No |
| Eliminar evidencia cerrada | No | No |

La API deriva `userId` del token. Los IDs recibidos sólo identifican recursos; nunca conceden ownership.

## 10. Modelo fotográfico

### Cámara y UX

- `ImageSource.camera` será una constante interna; no se expondrá galería.
- Android/iOS declararán permisos únicamente de cámara y ubicación requeridos.
- Al regresar la cámara se muestra inmediatamente un thumbnail temporal.
- La pantalla no espera hash, upload ni verify-batch.
- El archivo original se mueve primero a almacenamiento privado durable.
- Un worker procesa thumbnail/hash/persistencia.

### GPS

Mantener `lastKnownGoodPosition` con:

- edad recomendada máxima: 60 segundos;
- precisión máxima normal: 25 m;
- aceptar hasta 50 m con advertencia discreta si el entorno es difícil;
- nunca aceptar coordenadas 0/0;
- iniciar refresh discreto al abrir una etapa y al lanzar cámara;
- después de captura, asociar posición reciente válida;
- si no existe, foto queda `LOCATION_PENDING` y se solicita una lectura puntual;
- no mantener stream high-accuracy permanente;
- altitude sólo si el proveedor la entrega con valor válido.

Una etapa no puede finalizar mientras alguna foto activa esté `LOCATION_PENDING`.

### Estado local

```text
CAPTURED
→ LOCATION_PENDING/LOCATION_READY
→ PROCESSING
→ QUEUED
→ UPLOADING
→ UPLOADED_UNVERIFIED
→ VERIFYING
→ CONFIRMED
```

Errores mantienen estado y contexto, nunca reducen todo a `isSynced`.

### Storage API

Generalizar:

```text
STORAGE_ROOT/
  rv/{hydrantId}/{inspectionId}/{photoId}/...
  construction/base-surveys/{surveyId}/{photoId}/...
  tmp/{photoId}-{nonce}/...
```

Las rutas RV no cambian.

Se extraerá un `processPhoto(input, StorageAddress, photoId, hash)` donde `StorageAddress` resuelva segmentos validados mediante `safeStoragePath`.

### Verify multidominio

El servicio común verificará:

- fila DB;
- soft-delete;
- parent relation;
- original;
- thumbnail;
- SHA servidor;
- mapping de dominio;
- ownership del token.

Adapters:

- `RvPhotoIntegrityAdapter`;
- `ConstructionPhotoIntegrityAdapter`.

Construction considera mapping válido cuando exactamente uno de step/correction pertenece al mismo survey. No utiliza `visual_report_version_photos`.

### Políticas exactas

- `confirmed`: promover local a confirmado.
- `missing_original`: re-upload mismo UUID y archivo, si existe.
- `missing_thumbnail`: no re-upload; API regenera tras verificar original.
- `missing_mapping`: no re-upload; API repara sólo si FK/parent es inequívoco.
- `mapping_conflict`: incidencia, sin reparación inventada.
- `hash_mismatch`: recuperación controlada con mismo UUID/bytes originales.
- `not_found`: re-upload mismo UUID si existe archivo.
- `not_verified`: verificar/reconciliar; re-upload sólo si API lo solicita.
- `deleted`: no resucitar automáticamente.

### Retención local

- Nunca borrar antes de `CONFIRMED`.
- Retener originales durante al menos 90 días después de `CONFIRMED`.
- Además exigir que el survey esté `ACCEPTED` o `DELIVERED`.
- Nunca purgar evidencia de un survey rejected, pendiente o con incidencia.
- La limpieza será LRU, explícita, journalizada y sólo ante política aprobada.
- Conservar thumbnail y metadata aunque el original elegible sea purgado.
- Build 1 puede posponer el purge automático y ser aún más conservador.

## 11. Estrategia offline/sync

### Identidades

- `survey_id`, `step_id`, `photo_id`, `correction_id`: UUID v4 móvil.
- Todos persisten antes de cualquier navegación.
- Comandos contienen `operationId`, entity ID, payload version y timestamps.

### Boxes propuestas

- `construction_surveys_v1`
- `construction_steps_v1`
- `construction_corrections_v1`
- `construction_photos_v1`
- `construction_domain_queue_v1`
- `construction_media_queue_v1`
- `construction_operation_journal_v1`
- `construction_remote_snapshots_v1`
- `construction_sync_cursor_v1`
- `construction_preferences_v1`

### Orden de sync

1. perfil/rol;
2. upsert survey;
3. canonical location;
4. upsert/abrir step;
5. fotos con ubicación y hash;
6. verify-batch;
7. finalizar step;
8. ejecutar survey;
9. descargar cambios/revisiones;
10. correcciones;
11. reconciliar y refrescar snapshots/mapa.

### Idempotencia

- `PUT` para recursos con UUID conocido;
- `Idempotency-Key: construction:{operationId}`;
- mismo UUID + mismo contenido: éxito idempotente;
- mismo UUID + parent/hash distintos: `409`;
- finalización repetida: devuelve estado actual si coincide;
- transiciones incompatibles: `409 STATE_CONFLICT`.

### Retry

- exponencial con jitter;
- límites diferenciados dominio/media;
- pausa ante 401 mientras refresh resuelve;
- no borrar cola por timeout/5xx;
- 4xx estructural pasa a intervención;
- `deleted` y `mapping_conflict` nunca entran en loop automático.

### Merge local/server

Por `survey_id`. El snapshot servidor manda para:

- status de revisión;
- identifier/account editados por resident;
- historial;
- conflictos de cuenta.

Local manda para:

- operaciones aún no aceptadas por servidor;
- archivos;
- progress pendiente de sync.

Nunca “last write wins” sobre evidencia finalizada. Se conserva overlay local + snapshot remoto separado.

## 12. Mis levantamientos

### Fuentes

```text
Hive local
+ GET /construction/surveys
→ merge por survey_id
→ proyección visible
```

### Query propuesta

- contractor: ownership implícito por token;
- resident: scope autorizado;
- búsqueda normalizada por `display_identifier` o `account_number`;
- filtros por grupos de estado;
- cursor `(lastActivityAt,surveyId)`;
- default `limit=50`, máximo 100.

### Filtros UI

Chips horizontales:

- Todos;
- En proceso: `created/in_progress`;
- Ejecutados;
- Aceptados;
- Rechazados;
- Entregados.

Búsqueda local inmediata con debounce de red de 300–400 ms. Al estar online, el resultado servidor amplía el universo asignado; no reemplaza borradores locales.

### Duplicados

- Índice local normalizado por contractor.
- Antes de crear, advertir coincidencias locales.
- Con red, preflight servidor sobre propios.
- No hay constraint unique y la API siempre puede aceptar dos UUID.
- La UX pedirá confirmación explícita “Crear de todos modos” si existe coincidencia.
- La respuesta de creación incluirá `duplicateIdentifierWarning` y candidatos.
- No usar el nombre como clave ni devolver `409` sólo por duplicado.

## 13. Mapa

### Visibilidad

- Contractor: query siempre añade `contractor_user_id = token.userId`.
- Resident: universo determinado por scope de `construction.app_users`, preparado para una futura tabla territorial si se necesita.
- Marcadores locales se filtran también por usuario de la sesión.

### Coordenada canónica

Recomendación: capturar una ubicación específica del survey inmediatamente después de crear el UUID, en background.

Regla:

1. usar `lastKnownGoodPosition` si cumple edad/accuracy;
2. si no, obtener lectura puntual;
3. asignar la primera coordenada explícitamente confirmada;
4. una vez aceptada por servidor, queda inmutable para contractor;
5. las fotos conservan sus propias coordenadas y nunca recalculan el pin.

Ventajas: pin estable y disponible antes de completar la primera etapa. Riesgo: si se crea lejos del sitio, el pin sería incorrecto. Mitigación: mostrar preview y distancia respecto de primeras fotos; un resident podrá corregir la ubicación canónica mediante acción auditada futura, sin alterar GPS histórico.

### Proveedor/offline

- Conservar `flutter_map` + CARTO/OSM inicialmente.
- Tiles requieren Internet y no se prometerá mapa base offline.
- Los marcadores locales se conservan.
- Sin tiles en caché, mostrar superficie neutra, mensaje “Mapa base no disponible” y lista de puntos/distancias; no ocultar los levantamientos.

### Colorimetría accesible

| Estado | Color | Forma/icono adicional |
|---|---|---|
| En proceso | Azul `#1565C0` | círculo + herramienta |
| Ejecutado | Morado `#6A1B9A` | rombo + check pendiente |
| Rechazado | Rojo oscuro `#C62828` | triángulo + alerta |
| Aceptado/Entregable | Teal `#00796B` | círculo con check |
| Entregado | Gris azulado `#455A64` | cuadrado + paquete |

Siempre habrá texto en callout y leyenda. No depender exclusivamente de rojo/verde.

### Performance

- Reutilizar bounding box y debounce RV.
- Endpoint devuelve proyección de marcador, no detalle.
- Cache/snapshot incremental por `updatedSince`.
- Filtros simples locales para el snapshot cargado.
- Server-side para bbox, status y resident scope.
- Clustering a partir de ~250 marcadores visibles; configurable después de medir.
- Nunca N endpoints por pin.
- Detalle se carga sólo al tocar/abrir.

### Callout

- identifier;
- account si existe;
- status textual;
- etapa actual;
- contratista sólo para resident;
- última actividad;
- badge local/pendiente;
- botón “Ver detalle”.

## 14. Perfil

### Comparación de mejoras

| Función/dato | Origen | ¿Reutilizar? | Motivo | Cambios necesarios |
|---|---|---:|---|---|
| Nombre | RV + verification | Sí | Existe en login/`rv.users` | Leer `/construction/me` |
| Correo | Verification | Sí | Dato real de `rv.users` | API profile debe exponerlo |
| Teléfono | Verification | Sí | Dato real | Enmascarado parcial opcional |
| Cuadrilla | RV | Sí | Operativamente útil | Resolver sesión/crew |
| Rol | Nuevo dominio | Sí | Evita confundir `field` | Mostrar Contratista/Residente |
| ID installation | RV | Sí | Soporte operativo | Mostrar abreviado/copiar |
| Android/iOS version | Verification | Sí | Diagnóstico básico | Etiqueta “Sistema” |
| Marca/modelo | Verification | Sí | Soporte de cámara/GPS | `device_info_plus` |
| Versión app | Ambos | Sí | Soporte | `package_info_plus` |
| Conectividad | RV | Sí | Fundamental offline | Badge simple |
| Pendientes sync | RV | Sí | Operativo | Contar surveys/fotos |
| Estadísticas del día | RV | Parcial | Útil, pero no esencial | Adaptar a surveys; no bloquear Build 1 |
| Manual | Ambos | Sí | Apropiado | Manual propio |
| Exportar diagnóstico | RV | No en UI normal | Demasiado técnico | Menú oculto/support build |
| Auditoría local | RV | No para contractor | Ruido técnico | Sólo debug/support |
| Ajustes metrológicos | Verification | No | Fuera de dominio | Ninguno |
| ID del teléfono raw | Verification | Parcial | Útil para soporte | No mostrar identificador sensible completo |
| Logout | Ambos | Sí | Requerido | Conservar pending logout |

Perfil Build 1:

- encabezado nombre + rol construction;
- correo, teléfono, cuadrilla;
- dispositivo y versión;
- conectividad;
- “N levantamientos / M fotos pendientes”;
- acceso a sincronización;
- manual;
- cierre explícito de sesión.

## 15. Preparación funcional de RESIDENTE

La arquitectura incluirá:

- enum/guard de rol;
- shell navegable por rol;
- rutas resident declaradas pero protegidas por feature flag;
- DTOs de review;
- permisos API;
- status machine completa;
- filtros resident;
- edición de identifier/account;
- account conflict;
- correction rounds;
- scopes de mapa.

Home futura:

- `REVISIÓN DE BASE`;
- `REGISTRAR INSTALACIÓN`.

Revisión futura:

- default `EXECUTED`;
- búsqueda/filtros;
- evidencia read-only;
- aceptar/rechazar;
- editar identificador/cuenta;
- sin editar fotos/comentarios/timestamps.

Instalación futura:

- selector de `ACCEPTED` y `DELIVERED`;
- posibilidad de quitar filtro;
- entidad futura separada `hydrant_installation`.

Build 1 no implementará formularios completos resident ni instalación.

## 16. Endpoints API exactos propuestos

Todos bajo `/api/v1/construction`, autenticados con token `field`.

### Perfil/rol

```text
GET  /construction/me
```

Crea contractor por defecto idempotentemente y devuelve identidad RV, crew, construction role, device/session y resumen sync.

### Contractor surveys

```text
POST /construction/surveys/identifier-check
PUT  /construction/surveys/:surveyId
GET  /construction/surveys
GET  /construction/surveys/:surveyId
PUT  /construction/surveys/:surveyId/location
PUT  /construction/surveys/:surveyId/steps/:stepId
POST /construction/surveys/:surveyId/steps/:stepId/open
POST /construction/surveys/:surveyId/steps/:stepId/finalize
POST /construction/surveys/:surveyId/execute
```

`PUT survey` crea idempotentemente con UUID móvil. Si ya existe, valida ownership y payload inmutable.

### Correcciones contractor

```text
GET  /construction/surveys/:surveyId/corrections
PUT  /construction/surveys/:surveyId/corrections/:correctionId
POST /construction/surveys/:surveyId/corrections/:correctionId/finalize
```

El resident crea la ronda al rechazar; el `PUT` contractor sincroniza el UUID local esperado contra esa ronda, sin poder cambiar rejection metadata.

### Photos

```text
POST   /construction/surveys/:surveyId/photos
GET    /construction/surveys/:surveyId/photos
GET    /construction/surveys/:surveyId/photos/:photoId/content
DELETE /construction/surveys/:surveyId/photos/:photoId
POST   /construction/photos/verify-batch
```

Upload multipart:

- `photo`;
- `photoId`;
- `stepId` o `correctionId`;
- `sequenceNo`;
- `clientSha256`;
- `capturedAt`;
- `latitude`;
- `longitude`;
- `horizontalAccuracy`;
- `altitude`;
- `locationCapturedAt`;
- `metadata`.

DELETE sólo si parent está abierto y actor es owner contractor.

### Sync

```text
GET  /construction/sync/changes?cursor=...
POST /construction/sync/ack
```

El ack es opcional para telemetría, no requisito para integridad.

### Mapa

```text
GET /construction/map?minLat=&maxLat=&minLng=&maxLng=&status=&cursor=&limit=
```

Scope contractor/resident derivado del token.

### Resident futuro

```text
GET   /construction/resident/surveys
GET   /construction/resident/surveys/:surveyId
PATCH /construction/resident/surveys/:surveyId/identity
POST  /construction/resident/surveys/:surveyId/accept
POST  /construction/resident/surveys/:surveyId/reject
POST  /construction/resident/surveys/:surveyId/deliver
GET   /construction/resident/installations/base-options
```

Build 1 puede implementar contratos y tests API de revisión si se aprueba, manteniendo UI resident deshabilitada.

## 17. Cambios previstos en API

### Nuevos módulos

```text
src/modules/construction/
  construction.routes.ts
  construction.schemas.ts
  construction.domain.ts
  construction.authorization.ts
  app-users.service.ts
  surveys.repository.ts
  surveys.service.ts
  steps.service.ts
  corrections.service.ts
  review.service.ts
  map.service.ts
  sync.service.ts
  construction-photo.routes.ts
  construction-photo-integrity.adapter.ts
```

### Generalización

Mover el núcleo reusable de:

- `src/storage/photos.ts`;
- `src/modules/photos/photo-integrity.service.ts`;

hacia abstracciones neutrales, manteniendo wrappers RV con las firmas y rutas actuales.

Separar:

1. procesamiento binario/Sharp;
2. address resolver;
3. loader de fila de dominio;
4. evaluación de ownership;
5. evaluación de mapping;
6. repair policy;
7. auditoría.

### Retrocompatibilidad RV

Pruebas obligatorias:

- misma ruta RV física;
- mismo multipart;
- mismos códigos/respuestas aditivas;
- mismo endpoint `/photos/verify-batch`;
- mismo mapping de visual reports;
- old client continúa funcionando;
- migration construction no altera tablas RV salvo, si es necesario, una extensión genérica aditiva cuidadosamente separada.

Recomendación: no convertir `rv.photos` en tabla polimórfica. Construction tendrá su tabla propia y compartirá servicios de almacenamiento/integridad en código.

## 18. Creación de RevisionVisualStarter_TEST

### Nombre recomendado

Dado que producción real se llama `DDR001_Hidrantes_Prod`, recomiendo `DDR001_Hidrantes_TEST`, no `RevisionVisualStarter_TEST`. El nombre propuesto inicialmente podría hacer pensar que se restauró el starter histórico y no producción actual.

### Precheck read-only futuro

```sql
SELECT
    @@SERVERNAME AS server_name,
    DB_NAME() AS database_name,
    CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)) AS product_version,
    CAST(SERVERPROPERTY('ProductLevel') AS NVARCHAR(128)) AS product_level,
    CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) AS edition;

SELECT
    d.recovery_model_desc,
    SUM(CAST(mf.size AS BIGINT)) * 8.0 / 1024 AS size_mb
FROM sys.databases d
JOIN sys.master_files mf ON mf.database_id = d.database_id
WHERE d.name = DB_NAME()
GROUP BY d.recovery_model_desc;

SELECT name, physical_name, type_desc
FROM sys.database_files;

SELECT
    HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'BACKUP DATABASE'),
    IS_SRVROLEMEMBER('sysadmin');
```

### Backup/restore plan

1. Confirmar DB exacta `DDR001_Hidrantes_Prod`.
2. Elegir ruta de backup exclusiva y verificar espacio/permisos.
3. Ejecutar full backup `COPY_ONLY, CHECKSUM`.
4. Ejecutar `RESTORE VERIFYONLY WITH CHECKSUM`.
5. Obtener nombres lógicos mediante `RESTORE FILELISTONLY`.
6. Confirmar que `DDR001_Hidrantes_TEST` no existe.
7. Restaurar con `MOVE` a MDF/LDF nuevos y explícitos:
   - `DDR001_Hidrantes_TEST.mdf`;
   - `DDR001_Hidrantes_TEST_log.ldf`.
8. Usar `RECOVERY`; no `REPLACE`.
9. Validar nombre, schema, conteos y constraints.
10. Ejecutar `DBCC CHECKDB ([DDR001_Hidrantes_TEST]) WITH NO_INFOMSGS`.
11. Cambiar recovery TEST a `SIMPLE`, si operaciones lo aprueban.
12. Deshabilitar cualquier broker, CDC, mail, jobs, triggers o integraciones externas aplicables.
13. Crear login/runtime con mínimo privilegio; no usar la cuenta `sysadmin` actual.
14. Crear credencial separada para migraciones, temporal y auditada.
15. API local con `NODE_ENV=test`, `SQL_DATABASE=DDR001_Hidrantes_TEST`.
16. Ejecutar smoke read-only antes de migraciones.

No hay backups visibles en `msdb`; antes de crear TEST se debe investigar la política real de backup externa o confirmar que aún no existe.

### Copia completa vs sanitizada

Para primera integración controlada: restore completo por el realismo de usuarios, hidrantes, catálogos, revisiones y mappings.

Después del restore, antes de entregar acceso amplio:

- rotar/inutilizar refresh tokens y sesiones;
- desactivar o sanear admin users;
- no enviar emails/SMS;
- limitar acceso a un grupo de desarrollo;
- documentar que contiene datos productivos;
- opcionalmente pseudonimizar PII en una segunda copia para CI.

No usar la copia completa en CI compartido.

### Guardas

Todo script construction:

```sql
IF DB_NAME() <> N'DDR001_Hidrantes_TEST'
    THROW 51000, 'REFUSED: construction migration requires DDR001_Hidrantes_TEST.', 1;

IF DB_NAME() = N'DDR001_Hidrantes_Prod'
    THROW 51001, 'REFUSED: production database.', 1;
```

Además:

- `NODE_ENV=test`;
- allowlist de nombre;
- `SQL_PRODUCTION_DATABASE=DDR001_Hidrantes_Prod`;
- dry-run/schema verifier;
- migraciones sin `USE` dinámico;
- rollback explícito y revisado;
- SQL Server 2014: no `CREATE OR ALTER`, `STRING_AGG`, JSON nativo ni sintaxis moderna incompatible.

## 19. Storage TEST

Ruta recomendada en servidor:

```text
C:\APIS\DDR001-Hidrantes-TEST\storage
```

Nunca subdirectorio del storage productivo.

Configuración:

```text
STORAGE_ROOT=C:\APIS\DDR001-Hidrantes-TEST\storage
```

Reglas:

- cuenta de servicio TEST separada;
- ACL sin acceso de escritura al root productivo;
- readiness verifica sólo root TEST;
- fixtures bajo `fixtures/` o surveys reservados;
- limpieza sólo bajo root resuelto y validado que contenga `TEST`;
- nunca seguir symlinks/junctions fuera del root;
- job integrity TEST independiente y desactivado por defecto.

Matriz hardening:

- original ausente;
- thumbnail ausente;
- bytes alterados;
- mapping ausente;
- mapping conflictivo;
- soft-delete;
- fila ausente;
- re-upload mismo UUID;
- fallo SQL después de storage;
- orphan directory;
- verify de batches 1, 100 y paginados.

## 20. Wireframes textuales

### 1. Login

```text
[Logo DDR001 Levantamientos]
Documentación de bases de hidrantes

Nombre
Correo
Teléfono
Cuadrilla

[ INICIAR SESIÓN ]

Dispositivo registrado · versión
[estado de conexión]
```

Takeover: diálogo explícito con “Cerrar sesión anterior y continuar”.

### 2. Home contratista

```text
Hola, {nombre}                 [online/offline]

[ INICIAR NUEVO LEVANTAMIENTO ]
[ MIS LEVANTAMIENTOS ]

Pendientes de sincronizar: N

Inicio | Levantamientos | Mapa | Perfil
```

### 3. Nuevo levantamiento

```text
Nuevo levantamiento
Identificador visible *
[ Losa 1                         ]

La ubicación se está obteniendo…
[preview ubicación / precisión]

[ CREAR ]
```

Coincidencia: lista de nombres similares y confirmación de override.

### 4. Detalle/avance

```text
Losa 1                 [En proceso]
Cuenta: Sin asignar
Ubicación · última actividad · sync

✓ Creación
→ Preparación del terreno
○ Cimbrado
○ Armado
○ Colado
○ Descimbrado
○ Terminado

[ CONTINUAR ETAPA ]
```

### 5. Captura de etapa

```text
PREPARACIÓN DEL TERRENO
Fotos 1/4 mínimo 1

[thumbnail] [ + TOMAR FOTO ]
Ubicación: lista / pendiente
Comentario opcional
[................................]

[ FINALIZAR ETAPA ]
```

### 6. Visor de foto

```text
[foto completa]
Capturada: fecha/hora
GPS y precisión
Estado: Local / Subiendo / Confirmada

[ELIMINAR] sólo si etapa abierta
```

### 7. Correcciones

```text
Corrección · Ronda 2
Motivo del rechazo:
{texto resident}

Fotos mínimo 1
[thumbnails] [+ TOMAR FOTO]
Comentario opcional

[ ENVIAR CORRECCIÓN ]
```

### 8. Mis levantamientos

```text
[Buscar identificador o cuenta]
[Todos] [En proceso] [Ejecutados] ...

Losa 1      En proceso · Cimbrado
Sin cuenta  2 fotos pendientes

Base Norte  Rechazado
890-01      Requiere corrección
```

### 9. Filtros/búsqueda

Bottom sheet con estado, fecha/actividad y opción “Limpiar”. Los estados principales permanecen como chips.

### 10. Mapa

```text
[Todos] [Proceso] [Ejecutado] [Rechazado] ...
[Buscar en esta zona]

             mapa/placeholder offline
          ●  ◆  ▲

[mi ubicación] [mostrar todos]
```

### 11. Callout mapa

```text
Losa parcela 18
Cuenta: Sin asignar
Rechazado · Corrección 1
Actividad: hace 2 h
[pendiente local]
[ VER DETALLE ]
```

Para resident añade contratista.

### 12. Perfil

```text
[AB]  Ana Base
      Contratista · Cuadrilla Norte

Correo
Teléfono
Dispositivo / sistema
Versión de app

Conectividad
Levantamientos pendientes
Fotos por confirmar

[Sincronización]
[Manual]
[CERRAR SESIÓN]
```

### 13. Estado de sincronización

```text
Sincronización
Surveys pendientes: 2
Fotos:
  3 en cola
  1 subida sin verificar
  12 confirmadas
Incidencias: 0

[ SINCRONIZAR AHORA ]
Último intento...
```

### 14. Home residente futura

```text
[ REVISIÓN DE BASE ]
[ REGISTRAR INSTALACIÓN ]
Mapa · Perfil
```

### 15. Selección futura para revisión

```text
Buscar...
[Ejecutados default] [otros filtros]

Base Norte · Ejecutado
Contratista · fecha
[ REVISAR ]
```

### 16. Selección futura para instalación

```text
Buscar base...
[Aceptados] [Entregados] default

Losa 1 · 890-01 · Aceptado
[ SELECCIONAR BASE ]
```

## 21. Plan por fases de implementación

### Ramas únicas

- API: `feature/construction-field-app`.
- App: `feature/construction-field-app`.

No habrá ramas por rol, mapa o fotos.

### Fases

1. Aprobar este plan y congelar SSOT.
2. Preparar backup/restore TEST y storage TEST.
3. Crear rama API única desde el baseline hardened aprobado.
4. Crear schema/migración construction sólo contra TEST.
5. Implementar roles/profile y autorización.
6. Implementar surveys/steps/state machine.
7. Generalizar storage/integrity manteniendo RV.
8. Implementar photos construction y verify-batch.
9. Implementar sync/list/map endpoints.
10. Clonar repo vacío y ejecutar `flutter create`.
11. Configurar IDs, flavors, lints, CI, README/SSOT.
12. Implementar core auth/session/http.
13. Implementar persistencia/journal/sync.
14. Implementar creación y etapas.
15. Implementar cámara/GPS/hardening.
16. Implementar Mis levantamientos.
17. Implementar mapa.
18. Implementar perfil.
19. Implementar correcciones.
20. Certificación E2E Android físico.
21. Revisión de preparación resident.

### Commits API propuestos

1. `docs(construction): establish domain SSOT and contracts`
2. `test(db): add guarded construction migration harness`
3. `feat(construction): add roles and profile`
4. `feat(construction): add surveys and sequential steps`
5. `refactor(photos): generalize storage without changing RV paths`
6. `feat(construction): add hardened survey photos`
7. `feat(construction): add offline sync and survey queries`
8. `feat(construction): add map projection`
9. `feat(construction): add rejection and correction rounds`
10. `test(construction): certify authorization and integrity`

### Commits app propuestos

1. `chore: initialize Flutter levantamientos app`
2. `docs: add project SSOT`
3. `chore: configure environments identifiers and CI`
4. `feat(auth): add persistent DDR001 field session`
5. `feat(storage): add offline construction repositories`
6. `feat(surveys): add contractor survey workflow`
7. `feat(media): add camera-only GPS evidence`
8. `feat(sync): add hardened persistent synchronization`
9. `feat(surveys): add merged list search and filters`
10. `feat(map): add local-first survey map`
11. `feat(profile): add construction user profile`
12. `feat(corrections): add immutable correction rounds`
13. `test: certify contractor build on Android`

## 22. Tests

### Unit Flutter

- normalization de identifier;
- state machines;
- límites de fotos;
- lock de etapa;
- duplicate warning;
- merge local/server;
- integrity policy completa;
- retention eligibility;
- backoff;
- GPS freshness/accuracy;
- role guards;
- map colors/labels.

### Widget Flutter

- login/takeover;
- navegación inferior;
- home contractor;
- etapas;
- camera-only sin selector;
- location pending;
- filtros/búsqueda;
- map callout;
- perfil;
- correcciones;
- accesibilidad y tamaños de texto.

### Integration Flutter

- primer login;
- restauración offline;
- restart de proceso;
- survey y seis etapas sin red;
- cierre/reapertura;
- retorno de conectividad;
- upload/verify;
- rechazo/corrección;
- mapa con marker local.

### Unit/API

- schemas Zod;
- autorización contractor/resident;
- transición y secuencia;
- inmutabilidad;
- account conflict;
- idempotencia;
- storage address validation;
- integrity adapters;
- duplicate identifier advisory.

### SQL integration

- PK/FK/checks;
- composite FK de fotos;
- índices filtrados;
- dos IDs con mismo identifier;
- ownership;
- correction N;
- migración/rollback en DB temporal;
- guardas producción.

### API E2E

- contractor no ve/edita survey ajeno;
- resident no edita evidencia;
- IDOR con survey, step, photo y correction;
- mismo UUID repetido;
- UUID conflictivo;
- verify-batch sólo devuelve propios;
- missing/hash/mapping policies;
- lista/mapa/paginación/cursor.

### Android físico

Mínimo:

- dispositivo representativo de campo;
- permisos denegados/aceptados;
- cámara repetida;
- GPS interior/exterior;
- airplane mode;
- force-stop/restart;
- batería y memoria;
- 4+ fotos terminado;
- carga grande;
- red celular intermitente;
- takeover real;
- actualización de build conservando Hive/Secure Storage.

## 23. Riesgos

| Riesgo | Mitigación |
|---|---|
| Conexión local API apunta a producción | No ejecutar migraciones hasta crear TEST; guardas dobles |
| Cuenta SQL actual es sysadmin | Credenciales least-privilege separadas |
| No hay backups visibles | Resolver política de backup antes del restore |
| Copia productiva contiene PII/tokens | Revocar sesiones, restringir acceso y sanitizar copia secundaria |
| Storage TEST escribe en producción | Root y cuenta de servicio separados por ACL |
| Rama RV hardened no está en remoto | Publicarla/etiquetarla antes de depender de ella |
| Offline + etapa cerrada con upload pendiente | Archivo immutable local, comando finalize espera media confirmable |
| GPS lento/inexacto | Cache TTL/accuracy + refresh puntual |
| Foto perdida tras 201 | Sólo confirmed permite retención/purge |
| Mapping multidominio mal abstraído | Adapters explícitos, no tabla polimórfica |
| Regresión RV al generalizar storage | Golden paths y suite contractual RV |
| Pin creado lejos del sitio | Preview, comparación con primeras fotos y corrección auditada resident |
| Tiles sin red | No prometer mapa offline; conservar marcadores/lista |
| Muchos puntos | bbox, snapshot, cursor, clustering medido |
| Duplicados de identifier | Advisory local/server; UUID sigue siendo identidad |
| Account conflict | Registrar incidencia, no bloquear |
| Migración SQL 2014 | Harness real, sintaxis 2014 y rollback probado |
| Proyecto nuevo deriva hacia copia de RV | Arquitectura limpia y matriz de extracción |
| Fotos ilimitadas de terminado/corrección | Paginación, cuotas de upload y monitoreo; sin máximo de dominio |

## 24. Decisiones que ya están cerradas

No deben volver a preguntarse:

- La app será independiente.
- El repo oficial es `ddr001_levantamientos`.
- El proyecto Flutter se creará desde cero.
- No se renombra ni convierte RV.
- No se copia indiscriminadamente RV.
- Build 1 es contractor.
- Resident queda preparado.
- Auth es exactamente field session DDR001.
- Primer usuario construction es contractor salvo asignación previa.
- Roles construction no se mezclan con admin roles.
- UUID móvil es identidad.
- `display_identifier` es obligatorio y libre.
- `account_number` es nullable y diferente.
- Contractor no edita ambos después de crear.
- Duplicados de identifier son válidos en DB/API.
- Conflicto de cuenta no bloquea.
- Secuencia de pasos es fija.
- El término es DESCIMBRADO.
- Pasos 1–5: 1–4 fotos.
- Terminado: mínimo 4, sin máximo.
- Corrección: mínimo 1, sin máximo.
- Sólo cámara.
- GPS individual obligatorio.
- Stage finalizado es immutable.
- Resident no modifica evidencia.
- Sólo `confirmed` significa sincronizado.
- Deleted no se resucita.
- Original local se conserva hasta confirmed.
- Mis levantamientos, búsqueda, filtros, mapa y perfil son Build 1.
- Contractor sólo ve propios.
- No se reutiliza `rv.inspections`.
- No se usa `visual_report_version_photos` para construction.
- `hydrant_installation` será entidad separada.
- Una rama única por repositorio durante implementación.

## 25. Bloqueos o preguntas realmente necesarias

No existe un bloqueo para diseñar Build 1.

Antes de implementar sí deben quedar aprobados operacionalmente estos puntos:

1. Confirmar el nombre recomendado de la copia: `DDR001_Hidrantes_TEST` en lugar de `RevisionVisualStarter_TEST`.
2. Identificar la ruta válida de backups del servidor y por qué `msdb` no muestra historial.
3. Confirmar MDF/LDF físicos permitidos para el restore.
4. Revisar contenido de los SQL Agent jobs para demostrar que no apuntarán a TEST.
5. Crear una cuenta SQL y una identidad de servicio TEST sin `sysadmin`.
6. Confirmar URL HTTPS/VPN de la API TEST. La app RV actual admite una excepción HTTP productiva específica; no conviene ampliar esa excepción al nuevo proyecto.
7. Publicar o preservar de forma verificable la rama RV local hardened `e6b7438`, porque hoy no existe en el remoto.
8. Definir el icono final antes de un release distribuible; no bloquea desarrollo.

## 26. Recomendación final

El proyecto está técnicamente listo para comenzar implementación una vez aprobado este plan y preparado el entorno TEST aislado.

La secuencia crítica es:

1. asegurar DB/storage TEST;
2. congelar y publicar los baselines;
3. implementar primero contratos y hardening API;
4. crear después el proyecto Flutter limpio;
5. certificar el flujo offline completo y la integridad fotográfica en Android físico.

No debe iniciarse ninguna migración ni desarrollo móvil apuntando a `DDR001_Hidrantes_Prod` o al storage productivo.
