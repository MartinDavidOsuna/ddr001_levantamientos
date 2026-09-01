# Auditoría y certificación de resiliencia — DDR001 Levantamientos

Fecha base: 2026-08-30
Rama auditada: `feature/contractor-build-1`
Baseline: `f3a6afdfb65a2fb8325a24f9e777b56446f8f7e5`
Alcance: **solamente la app móvil**. No se modifica la API.

## 1. Objetivo de certificación

La app se considera certificable únicamente cuando:

1. Ningún levantamiento, comentario o evidencia capturada y aceptada por la app desaparece por pérdida de red, timeout, cierre forzado, muerte del proceso o reinicio del equipo.
2. Un timeout ambiguo después de enviar datos no crea duplicados ni pierde la operación; el cliente reconcilia contra servidor antes de repetir.
3. Una foto nunca se considera sincronizada por recibir HTTP 2xx del upload: requiere verificación de integridad `confirmed`.
4. Los archivos locales no se eliminan mientras exista una operación remota no confirmada.
5. La cola persiste entre procesos y conserva dependencias causales por levantamiento.
6. La app no mantiene GPS de alta precisión ni sondeos de conectividad agresivos fuera de una ventana funcional necesaria.
7. Procesamiento de archivos grandes evita copias completas innecesarias en el heap de Dart.
8. Cualquier error de un levantamiento queda aislado y no impide avanzar otros levantamientos listos.

## 2. Patrones heredados de la optimización RV que deben conservarse

- UUID estable generado en cliente.
- `Idempotency-Key` estable para mutaciones reintentables.
- Cola persistente y causal.
- Refresh de sesión single-flight.
- No borrar credenciales por problemas temporales de red/5xx.
- Reconciliación al iniciar y antes de reintentar operaciones ambiguas.
- Upload y confirmación de integridad como estados separados.
- SHA-256 por streaming y representación de upload durable/reutilizable.
- Evidencia finalizada inmutable.
- Recuperación tras muerte de proceso sin borrado local.

## 3. Hallazgos del baseline

### A. Correcto / reutilizable

- `ApiClient` tiene timeouts finitos y refresh single-flight.
- La cola registra intentos y `nextAttemptAt` de forma persistente.
- `ConstructionSyncScheduler` respeta dependencias y procesa como máximo una operación lista por levantamiento por ronda.
- Creación de survey, apertura/cierre de etapa, upload, delete y cierre de corrección usan claves idempotentes estables.
- La sincronización reconcilia el detalle del servidor antes de ejecutar la cola. Esto cubre el caso `servidor confirmó + respuesta perdida`.
- Una foto sólo habilita cierre de etapa si su estado local es `confirmed`.
- El GPS high-accuracy está limitado a flujos de captura/pending evidence, no es permanente.

### B. Riesgos P0 antes de certificar

1. **Captura no durable durante el retorno de cámara.** `image_picker` entrega primero un archivo temporal y después la app lo normaliza a almacenamiento privado. Una muerte de proceso en esa ventana puede dejar una captura sin registro recuperable. Debe migrarse al patrón de captura durable con destino preasignado, o implementar recuperación explícita de `retrieveLostData` y staging journalizado.

2. **No existe operation journal multi-recurso.** Guardar archivo, foto Hive, survey Hive y cola son escrituras independientes. Un crash entre ellas puede dejar archivo huérfano, foto no enlazada o evidencia sin comando de sync. Se requiere journal o reconciliador local determinista al bootstrap.

3. **Borrado local antes de confirmar delete remoto.** En `deletePhoto`, los archivos y metadata se eliminan antes de persistir/confirmar el tombstone remoto. Un crash intermedio puede dejar evidencia en servidor sin forma local de reconciliarla. El flujo debe convertirse a `tombstone -> enqueue delete -> confirm remote -> purge local`.

### C. Riesgos P1 de recursos/robustez

1. El fallback offline consulta conectividad cada 3 s. Debe eliminarse o elevarse a una frecuencia conservadora (p. ej. 30–60 s) y depender principalmente del stream de conectividad; además, `connectivity_plus` sólo indica transporte, no salud de API.
2. GPS `best` con `distanceFilter: 0` es adecuado durante una captura breve, pero debe medirse en batería y detenerse de forma verificable al salir del flujo y al resolver todas las ubicaciones pendientes.
3. La reconciliación hace un `detail` por survey pendiente. Debe medirse con 50/100 levantamientos pendientes y evitar ciclos redundantes; optimizar sólo desde cliente, sin requerir endpoint nuevo.
4. El `AppController` es monolítico y emite múltiples `notifyListeners`; perfilar rebuilds en listas/mapa durante sync masivo.
5. No existe política automática de purge certificada. Mantener estrategia conservadora: no purgar originales automáticamente en esta certificación.

### D. Riesgo P2 / mantenibilidad

- El E2E actual es sólo un guard de configuración y no ejecuta un flujo real.
- CI ejecuta analyze + unit tests, pero no integración Android ni build de APK de prueba.

## 4. Cambios app-only requeridos

### Fase 1 — Zero-loss local

- Añadir `OperationJournalRepository` o reconciliador equivalente con estados `prepared/committed/recovered`.
- Antes de exponer una foto en UI, asegurar archivo durable + metadata mínima persistida.
- Escanear al bootstrap:
  - archivos de evidence sin registro;
  - registros de foto sin archivo;
  - foto enlazada a survey pero sin upload/verify queue;
  - queue para foto inexistente;
  - operaciones `uploading/verifying` heredadas de muerte de proceso y regresarlas a estado recuperable.
- Nunca borrar automáticamente un survey o foto porque no aparezca en respuesta servidor.

### Fase 2 — Media eficiente

- SHA-256 por stream (implementado en rama de auditoría).
- Mantener una representación de upload determinista por `photoId`; no recomprimir en cada retry.
- Hash de recuperación sólo cuando haya evidencia de archivo cambiado/corrupto; no recalcular en cada retry normal.
- Thumbnail separado del original; listas usan thumbnail, nunca decodifican originales completos.

### Fase 3 — Red y sincronización

- Estado real: `transportAvailable`, `apiReachable`, `syncing`, `degraded`; no interpretar Wi-Fi/celular como servidor disponible.
- Reintentos sólo desde cola persistente para mutaciones.
- Backoff exponencial con jitter y límite razonable; reintento manual puede romper cooldown sin borrar intentos/historial.
- Tras `sendTimeout/receiveTimeout/connectionError` de una operación idempotente, marcar resultado **ambiguo** y reconciliar antes de retransmitir.
- 409 de dependencia se conserva en cola; 409 estructural pasa a `requiresReview` y no entra en loop caliente.
- Un fallo de survey no bloquea otros surveys listos.

### Fase 4 — Recursos del teléfono

- Remover polling de 3 s o llevarlo a >=30 s sólo como fallback.
- Confirmar que GPS se apaga al cerrar captura y al resolver pending locations.
- Perfil Android físico con 100 surveys, 400 thumbnails y 20 fotos pendientes.
- Medir RSS/PSS, Java/Dart heap, CPU, frames lentos, red y batería durante:
  - arranque offline;
  - login ya persistido;
  - scroll de lista;
  - mapa;
  - captura de 10 fotos;
  - sync de 20 fotos;
  - 30 min offline sin interacción.

## 5. Matriz de fault injection obligatoria

| Caso | Inyección | Resultado exigido |
|---|---|---|
| F01 | modo avión antes de crear survey | survey visible tras reiniciar, create en cola |
| F02 | kill después de crear survey | survey y cola reaparecen |
| F03 | kill al regresar de cámara | captura recuperada o claramente no aceptada por la app; nunca “desaparece” después de mostrarse como guardada |
| F04 | kill después de archivo durable y antes de Hive | bootstrap repara mediante journal/scanner |
| F05 | kill después de Hive y antes de enqueue | bootstrap reconstruye queue |
| F06 | conexión cae durante multipart | archivo local intacto, upload sigue pendiente |
| F07 | servidor guarda foto y cliente recibe timeout | reconcile detecta mismo photoId; no duplica |
| F08 | upload 201 + verify `not_verified` | permanece local y re-verifica |
| F09 | verify `missing_original` | re-upload mismo UUID/bytes |
| F10 | verify `hash_mismatch` | incidencia/re-upload controlado; nunca borrar original |
| F11 | verify `mapping_conflict` | requires review; sin loop ni relación inventada |
| F12 | refresh token timeout | sesión y trabajo local permanecen |
| F13 | refresh recibe revocación definitiva | sesión se limpia; datos locales permanecen |
| F14 | 20 surveys: uno da 409 estructural | los otros 19 continúan |
| F15 | delete foto + kill en cada frontera | tombstone recuperable; archivo sólo se purga tras confirmación |
| F16 | reinicio del teléfono con retries en cooldown | cola persiste y retoma cuando corresponde |
| F17 | Wi-Fi conectado sin Internet | no loop caliente; estado degraded/offline-server |
| F18 | API 500 durante 15 min | backoff; cero pérdida; recuperación automática |

## 6. E2E

### Nivel A — determinista, obligatorio en cada PR

Pruebas con fake server/adapter que controlen exactamente:

- timeout antes de commit;
- timeout después de commit;
- 409 dependency;
- 409 structural;
- 500;
- 401 + refresh exitoso;
- refresh temporalmente fallido;
- verify matrix completa.

Deben cerrar/reabrir `LocalStore` entre fases para simular process death.

### Nivel B — Android físico + TEST API, obligatorio para release

Ejecutar con flavor/config TEST y credenciales fuera del repo:

1. login real;
2. crear survey;
3. capturar evidencia real con GPS;
4. cortar/restaurar red durante upload;
5. `adb shell am force-stop <package>` en puntos controlados;
6. relanzar y comprobar local recovery;
7. completar etapa;
8. reiniciar equipo y repetir sync;
9. validar servidor por endpoints GET/verify existentes.

No ejecutar fault injection destructivo contra producción.

## 7. Gates READY / NOT READY

### READY

- `flutter analyze`: 0 errores.
- `flutter test`: 100% pass.
- E2E Nivel A: 100% pass, incluyendo F01–F18 aplicables.
- Android físico: 3 corridas consecutivas sin pérdida ni duplicados.
- 20 uploads con al menos 5 interrupciones aleatorias: 20/20 terminan `confirmed`.
- 10 force-stops en fronteras de persistencia: 0 registros/fotos desaparecidos después de haber sido confirmados localmente.
- Ningún retry loop >1 req/s por operación fallida.
- GPS stream y timers de fallback detenidos cuando no son necesarios.
- Sin OOM/ANR en captura/sync del dataset de certificación.

### NOT READY

Cualquier pérdida de evidencia local, duplicado remoto no reconciliable, borrado previo a confirmación, cola irrecuperable, sesión borrada por error temporal o incapacidad para confirmar fotos deja el build en `NOT READY`.

## 8. Cambios de API

**No se detecta un cambio obligatorio de API para implementar esta certificación.** El contrato actual aporta UUID cliente, idempotencia, detail y `verify-batch`, suficientes para recuperación app-side.

Único bloqueo condicional a verificar en TEST: si una petición con `Idempotency-Key` ya procesada por servidor pero cuya respuesta se perdió no puede reconciliarse de forma estable por `surveyId/photoId`, o si repetir exactamente la misma clave/payload produce un efecto duplicado, eso sería un defecto obligatorio de API. No se propone ni se implementa ningún cambio de API mientras esa condición no sea demostrada.
