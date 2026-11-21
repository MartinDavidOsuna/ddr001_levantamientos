# HAPI-3.1 — Sincronización de documentos, exclusivamente TEST

Base de contrato auditada: API `1181a7070b0937900704b70480e6bd5db10c59a5`.
No habilitar en producción. No instalar sobre una app con datos de campo para
probar. La variante `.hydrotest` conserva su entrada sintética y sin INTERNET;
no se convierte en cliente de API. No se enviaron datos del Pixel en esta etapa.

## Activación reproducible

En una instalación normal TEST independiente, con sesión Field real TEST de
residente y gabinete TEST existente, compilar con el entrypoint `lib/main.dart`:

```sh
flutter build apk --debug -t lib/main.dart \
  --dart-define=APP_ENV=test \
  --dart-define=API_BASE_URL=http://HOST_TEST_AUTORIZADO:3003/api/v1 \
  --dart-define=HYDROSTATIC_SYNC_ENABLED=true
```

Reemplazar HOST_TEST_AUTORIZADO sólo después de verificar identidad y accesibilidad
del entorno; el ejemplo no es una dirección de despliegue verificada. No usar
`ORG_GRADLE_PROJECT_hydrostaticTest=true` con este flujo. La bandera es false por
defecto y no habilita producción. El host productivo está rechazado por configuración.
La API debe exponer capabilities `hydrostatic-sync-v1`, environment TEST,
documentPersistence y durableReceipts. Sin capacidades compatibles no hay POST.

## Persistencia y causalidad

`hydrostatic_sync_v1` es una caja Hive exclusiva, con checksum por registro,
esquema 1, escritor serial y un registro atómico por UUID de prueba. Contiene:

- propietario e instalación, cabeza remota, revisión/hash aceptados;
- un comando congelado activo: UUID, timestamp, expectedVersion, payloadJson
  exacto y SHA-256, intentos, próximo reintento y estado de entrega;
- recibos COMMITTED ligados al fingerprint del comando;
- segmentos del journal congelados, con bytes JSON locales y manifiesto/hash.

La captura original permanece en las cajas hidrostáticas existentes; syncState
sigue LOCAL_ONLY porque forma parte del contrato fuente. La entrega se modela
como sidecar, sin confundirla con resultado hidráulico. No se marca reconciliación
completa. No se cambian timestamps, actor, consecutivo, fotografías ni snapshots.

El snapshot se toma bajo el escritor local, después de resolver su journal. Se
fija primero un pin `syncProtected:<UUID>` en metadatos propios y después el
outbox. Una interrupción entre ambos conserva un pin preventivo y el siguiente
escaneo reconstruye el envío aún no comprometido. Un comando ya congelado nunca
cambia bytes/UUID por un reintento. No se generan nuevos comandos para la misma
revisión mientras exista uno sin resolver. Cambios locales posteriores se envían
tras ACK con UPDATE_DOCUMENT, versión y baseSourceHash aceptados. La declaración
de video también usa UPDATE_DOCUMENT (comando permitido por HAPI-2), conserva su
UUID/timestamp local y no envía un video.

Se conserva todo el journal local. HAPI-2 sólo recibe historyManifest; no recibe
segmentos físicos. Las capturas se declaran con su intención/metadatos; cambios
sólo de intención sin nueva revisión de documento se conservan localmente hasta
el siguiente checkpoint de documento. No se fabrica una revisión para eludir el
contrato de inmutabilidad de sourceRevision.

## Estados, interrupciones y conflictos

PENDING → IN_FLIGHT (durable antes del POST) → recibo validado y cabeza aceptada
(atómicamente). Un error incierto conserva SENT_UNKNOWN. Tras reinicio o respuesta
perdida se consulta GET operations; un 404 de operación inexistente permite
repetir el mismo comando, con Idempotency-Key y If-Match originales.

401/403 pausan; 409 conserva CONFLICT con sync-status remoto; rechazo definitivo
conserva REJECTED. No se sobrescribe el documento ni se adopta automáticamente una
versión remota. REINTENTAR / RECUPERAR RECIBO busca primero el recibo y, si no
existe, repite exactamente la operación. Un conflicto real de contenido sigue
bloqueado para revisión; HAPI-2 no ofrece un comando administrativo de reconciliación.
El resto de expedientes puede continuar. No se aplica última escritura gana.

Se verifica usuario/sesión/instalación antes y después de las operaciones. El
cliente compartido sólo añade comprobaciones opt-in de sesión e instalación;
los consumidores existentes sin estas opciones no cambian. Su refresh conserva
el envelope y no reproduce la petición bajo otro login. Un nuevo login del mismo
actor/instalación puede recuperar la operación, manteniendo la sesión histórica
original del documento; el backend verifica esa atribución histórica.

Backoff exponencial con jitter y retryAt durable, máximo aproximado 30 minutos.
Disparadores: inicialización autorizada, guardado durable de documento, retorno a
la app, conectividad y revisión cada 30 segundos mientras el proceso exista.
No hay servicio permanente con app cerrada. La apertura vuelve a escanear fuente
más outbox. No se hacen peticiones si no hay entregas pendientes. Un problema al
abrir el outbox no impide conservar la captura local y permite reintentar.

## Fotografías y eliminación

No se llama a endpoints de subida ni se lee/transporta contenido fotográfico. Se
conservan originales y hashes. COMMITTED significa documento recibido, no archivo
verificado, prueba certificada ni historial transferido. UI: «Documento recibido ·
fotos e historial pendientes de transferencia». Un original perdido/corrupto no
queda reparado por un ACK. Su recuperación sigue siendo necesaria para HAPI-4.

La eliminación de desarrollo mantiene sus guardas y está además bloqueada en
repositorio y UI cuando existe el pin de envío, incluso después de un recibo.
No se borran outbox, recibos, journal ni fotos al logout, conflicto o refresh.
No hay endpoint DELETE ni limpieza global.

## Validación reproducible local

```sh
flutter analyze
flutter test test/hydrostatic
flutter test
HYDROSTATIC_CONTRACT_FIXTURE=/tmp/hapi2-checkpoints.json \
  flutter test test/hydrostatic/sync_contract_test.dart
../ddr001_api/node_modules/.bin/tsx tool/hydrostatic/verify_hapi2_contract.ts \
  ../ddr001_api /tmp/hapi2-checkpoints.json
```

El último comando valida 15 checkpoints Flutter y 15 replays en el repositorio
real HAPI-2 con transacción en memoria. No abre SQL ni HTTP y no certifica un
despliegue. Fixtures sintéticos cubren PASSED, FAILED, descarte y revisión temporal.
La integración remota TEST y recuperación en teléfono autorizado quedan pendientes
hasta contar con conectividad y consentimiento de envío de esos fixtures.
