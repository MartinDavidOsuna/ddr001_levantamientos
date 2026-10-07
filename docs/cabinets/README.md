# DDR001 Nuevos Hidrantes — macroetapa móvil 2

Implementación en `feat/ddr001-cabinets-mobile`, creada mediante worktree desde
`origin/main` **0b78ac7** de `ddr001_levantamientos`. Versión de integración
`1.5.0+11`; no es una publicación productiva. El checkout original
`feature/map-coordinates-1.4.1` y sus cambios sin commit se conservaron íntegros.
Los cambios de mapa/galería se integraron posteriormente en `c565e11`.

## Contrato comprobado

El 2026-10-05 se comprobó mediante GitHub CLI que
[API PR #15](https://github.com/MartinDavidOsuna/ddr001_api/pull/15) permanece
**OPEN, draft**, sin integrar en main, HEAD
`46b0265b9c8698363f3eca73257bc47382c4d8f2`.
Esta rama móvil depende de ese PR; no debe integrarse/desplegarse aisladamente.

La API utilizada se ejecutó desde el checkout Mac `/Users/martino/DEV/ddr001_api`
en ese commit, `http://127.0.0.1:3003/api/v1`. `/version` confirmó el SHA con
sufijo `-development`, entorno `test` y `features.constructionCabinets=true`.
Preflight SQL real: `DDR001_Hidrantes_TEST`, servidor `WIN-5RQE8N8NQ9V`,
SQL Server 2014 `12.0.4237.0`. Almacenamiento exclusivo de la ejecución:
`/Users/martino/DEV/ddr001_api/.storage/construction-test`.
El worktree Windows reportado por macroetapa 1 es evidencia histórica, no el
servidor usado aquí. Las fotos generadas en este recorrido están en el storage
local de esta API; no se supone que archivos históricos de otro host existan allí.

Fuentes: `docs/cabinets-domain.md`, `docs/cabinet-closure-policy.md`, OpenAPI y
`src/modules/cabinets/{domain,commands,repository,photos,cabinet.routes}.ts` del
commit indicado. El fixture JSON bajo `test/cabinets/fixtures` procede del
endpoint real de catálogo y sólo se utiliza en tests. En runtime no existe
catálogo alternativo, Excel, ni valores de cumplimiento prellenados.

## Funcionalidades

- Inicio exclusivo de residentes **Field Construction**: Registrar gabinete,
  Revisión de base, Revisión de hidrante. Admin/superadmin no reciben permisos
  de gabinete por equivalencia reviewer. Listados, expedientes, cámara, fotos
  y acciones vuelven a comprobar acceso; revocación 401/403 oculta el caché.
- Primera descarga y autorización requieren conexión. Producción mantiene
  deshabilitado este módulo en esta macroetapa (`APP_ENV=production`); su
  activación coordinada queda para macroetapa 4. No se cambia la URL productiva.
- Listado con búsqueda UID/base/cuenta, filtros estado/modelo y páginas de 25.
  Se descargan **todas** las páginas autorizadas del backend (100 por request).
  El endpoint sólo admite búsqueda por UID y estado: búsqueda por base/cuenta
  y modelo se hace sobre todos los expedientes descargados, sin inventar query
  parameters. Cada página recibida queda persistida si la red se interrumpe.
- Escaneo QR con `mobile_scanner`, cámara detenida al salir/suspender; entrada
  manual equivalente. Host/ruta estrictos, checksum ISO 7064 del backend,
  representación visible, UUID técnico separado y deduplicación local serializada.
- Catálogo versionado por expediente. Ocho variantes reconciliadas, unidades
  físicas individuales, series como texto, excepciones obligatorias pendientes,
  evidencia compartida sin duplicar archivos y confirmación de placas legibles.
- Revisión de piezas agrupada; guardado automático de formularios. Una edición
  invalida validación local. Cambiar modelo/automatización emite el comando
  explícito, conserva fotos/historia y obliga a revisar piezas/checklist afectados.
- Instalación con selección paginada de bases accepted/delivered, cuenta
  propuesta y resolución expresa de discrepancias, GPS propio con fecha y
  precisión, diez bloques de checklist, progreso y accesos a pendientes.
  Cada punto requiere respuesta individual; se retiró la confirmación masiva de bloques.
- Motivos, pruebas diferidas y evaluación de impacto consumen la política
  descargada; no se calculan umbrales eléctricos/hidráulicos. Fotografías son
  relaciones de evidencia, no un Sí. La prevalidación local es orientativa;
  el servidor conserva autoridad sobre elegibilidad, exclusividad y cierres.
- Revisión final sobre el expediente existente, declaraciones de consulta y
  comprobación, foto actualizada y dictamen. Aprobación sólo confirmada por
  API. Correcciones invalidan cierre/aprobación; un dictamen negativo requiere
  resolución explícita. No existe operación de entrega formal.
- Historial paginado, actor, tiempos y versiones, intentos conservados,
  comparación local/remoto y resolución explícita. UID duplicado abre la
  identidad remota y conserva el expediente original como conflicto archivado.
- Bases: `ConstructionApi.list` recorre todas las páginas manteniendo búsqueda
  y permisos. `waived` se conserva como `StepState.waived`, se presenta
  **Dispensada** y no admite editar, finalizar ni capturar/subir nuevas fotos.

## Persistencia y garantías

`cabinets_documents_v1` contiene un valor atómico por UUID: documento servidor,
borrador, actor, catálogo, operaciones completas, respuestas y fotos. Cada
mutación local se serializa y hace `flush` antes de declarar éxito. El journal
retiene UUID, cuerpo, expectedVersion, fecha y actor de cada intento; los ACK y
los intentos sustituidos se conservan. Los borradores no viajan bajo otro actor.
Otro residente puede continuar documentos remotos cuando no hay captura local
ajena pendiente; las operaciones ajenas necesitan su sesión original.

Migración **aditiva** propia schema 1: se crean cajas
`cabinets_documents_v1`, `cabinets_media_documents_v1`,
`cabinets_media_photos_v1`, `cabinets_media_queue_v1`,
`cabinets_media_metadata_v1`, `cabinets_media_journal_v1`.
Una versión desconocida se rechaza sin limpiar datos. No se toca el schema 3 ni
las cajas de bases. La migración UUID existente preserva waived como estado
cerrado de mayor precedencia. No se borran preferencias, sesiones ni evidencias.

El motor `PhotoCaptureService` se reutiliza con directorio `cabinets/` y cajas
propias: staging, copia durable, original, representación JPEG, miniatura,
SHA-256 y journal previo a cámara. GPS se captura por foto, separado del GPS de
instalación/base. Una foto sin GPS se conserva, queda inutilizable como evidencia
hasta nueva captura válida y nunca recibe una coordenada tardía de otra ubicación.
La recuperación vuelve a vincular capturas durables después de reiniciar; si el
sistema perdió el resultado antes de hacer durable el archivo, se usa la misma
recuperación de journal/cache del motor existente, sin prometer recuperar bytes
que Android no haya conservado. Los archivos faltantes/alterados no se borran ni
se sustituyen por imágenes distintas bajo el mismo UUID.

La sincronización ocurre al encolar, volver la conectividad, abrir/reanudar y
Reintentar ahora. Se comprueba catálogo compatible antes de enviar. Backoff
exponencial por intento; un conflicto detiene sólo ese expediente. Registro
precede fotos/cierre; las referencias se suben y verifican antes de cada comando
que las necesita. Las fotos listas también se envían independientemente de su
relación. El HTTP de carga no confirma integridad: se exige `storageVerified`
en verify. Se pueden reparar archivos remotos desde los mismos bytes locales.

Un timeout deja estado `sending`: primero se consulta `operations/{operationId}`.
404 permite repetir **exactamente** el cuerpo original. La versión no se cambia
automáticamente para vencer un conflicto. Resolver explícitamente crea un nuevo
UUID/versión, conserva el intento anterior y usa las capturas revisadas. Las
respuestas de auth no eliminan colas. El interceptor vincula escrituras al actor
esperado y no aplica un refresh a una sesión diferente.

Android/iOS: los timers viven en el proceso. No se implementa servicio permanente,
WorkManager ni background fetch; no se promete enviar con la app terminada.
Al volver a abrir se recuperan Hive/journal y se reanuda el envío. La autoridad
offline procede del último permiso verificado de ese usuario; una revocación
remota sólo puede conocerse al recuperar conexión.

## Límites de integración

- Backend PR #15 sigue siendo dependencia pendiente. No se modificó la API para
  aparentar compatibilidad ni se ejecutó SQL productivo.
- Descarga completa de documentos permite búsqueda exacta por base/cuenta con
  el contrato actual, pero cuesta una consulta de detalle por gabinete. No existe
  snapshot de paginación: altas concurrentes se reconcilian en la siguiente
  actualización. Un endpoint indexado de búsqueda ampliada podrá optimizarse
  en una macroetapa posterior, sin limitar ahora a los primeros 100.
- Las evidencias remotas se descargan expresamente al consultarlas; sin descarga
  previa una foto remota necesita conexión. Catálogo y documentos se conservan.
- Conflicto UID no fusiona automáticamente fotos/capturas de dos UUID. El residente
  consulta ambos expedientes; el original se conserva íntegro y queda de lectura.
- Validación física de cámara/QR/GNSS, actualización sobre copia representativa
  de datos de campo y pruebas iOS en dispositivo quedan fuera de la certificación
  automatizada descrita. Nunca se usó un dispositivo de campo para escribir.

[Contrato consumido](contract-matrix.md) · [TEST reproducible](testing.md) ·
[Resultados](validation.md). Scanner: [documentación del paquete](https://pub.dev/packages/mobile_scanner).

## Prevención de errores humanos (2026-10-06)

Ver [protecciones y validación](human-error-prevention-20261006.md). Incluye bloqueo
contra doble envío, confirmaciones de identidad/base/dictamen, conservación de piezas
compatibles al corregir modelo, motivos validados, revisión visual de originales,
advertencias de series/distancia, captura GPS reciente y conservación de borradores.
La conservación de piezas compatibles requiere también el cambio en la API; no basta
con actualizar únicamente el APK.
