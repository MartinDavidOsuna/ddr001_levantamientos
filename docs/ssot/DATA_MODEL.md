# Local Data Model

Schema `3`, boxes: `construction_surveys_v1`, `construction_photos_v1`, `construction_sync_queue_v1`, `construction_metadata_v1`.

## UUID canonicalization rule

Todos los UUID se representan internamente como `trim().toLowerCase()`. El case
nunca participa en identidad. Deserialización API/Hive, lookups, referencias de
survey/photo/correction, keys Hive y queue pasan por la utilidad central.

La migración UUID v2 agrupa keys por UUID canónico, escribe y valida primero la
entidad fusionada bajo la key lowercase, elimina después únicamente las keys
duplicadas y finalmente marca `uuidCanonicalizationV2=complete`. Es idempotente
y una interrupción antes del marker se recupera repitiendo el mismo plan.

- `ConstructionProfile`: identidad RV y rol recibido.
- `BaseSurvey`: UUID, snapshot contractor, identifier/account, estado local/servidor/sync, canonical, steps/corrections.
- `SurveyStep`: 1–6, open/locked/completedLocal/completedServer, comentario y photo IDs.
- `ConstructionPhoto`: UUID, paths, SHA-256, GPS individual, contexto, estado hardened y `purpose` opcional. Paso 6 usa `north`, `east`, `south`, `west` o `additional`; fotos anteriores siguen siendo compatibles con null.
- `CorrectionRound`: round, estado, comentario y fotos.
- `SyncQueueItem`: operación, dependencias, intentos y siguiente ejecución.

Los tokens no forman parte de Hive.

El merge conserva evidencia, comentarios, paths, hashes, etapas y correcciones
locales. El estado confirmado, cuenta no-null, ubicación canónica, rechazo y
timestamps provienen de la variante server. Si existen operaciones pendientes,
se conserva el estado funcional local y `syncState=pending`. `remote null` no
reemplaza una cuenta local pendiente.

## Location Evidence Model

`ConstructionPhoto` separa `capturedAt` de `locationFixAt` y persiste
`locationAcquiredAt`, accuracy, altitude accuracy, heading, speed, source,
delta temporal, confidence, distancia a canonical, consistency e integrity flag.
`locationState` es `pending`, `provisional`, `confirmed` o `unresolved`.
Fotos legacy con coordenadas migran como confirmed; fotos sin coordenadas como
pending. La señal `mocked` se conserva para auditoría sin bloqueo automático.
