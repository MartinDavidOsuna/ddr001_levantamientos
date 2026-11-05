# Corrección de eliminación local de Gabinetes

## Resultado
Corrección implementada y validada con datos sintéticos. Sin commits, push, merge, despliegues ni operaciones sobre teléfonos. No se modificaron API, SQL, NAS ni producción.

## Git y preservación
- Repositorio: https://github.com/MartinDavidOsuna/ddr001_levantamientos.git
- Directorio: /Users/martino/DEV/ddr001_levantamientos
- Rama inicial/final: feat/hydrostatic-mobile-sync.
- HEAD inicial/final: 9a903488a0d63ef50149b6d2ff1ca0b9eabb287e.
- El árbol ya tenía desarrollo HAPI-3.1 pendiente. Se compararon SHA-256 de los 18 archivos modificados/sin seguimiento preexistentes inventariados, excluyendo informes: todos permanecen idénticos. Se preservó también el Excel ajeno al alcance. No se crearon worktrees ni se cambió de rama.

## Causa exacta y recorrido
En `lib/features/cabinets/cabinet_pages.dart:1081`, el botón «Eliminar sólo de este teléfono» abre `CabinetDeleteDialog(localOnly: true)`, solicita el UID y llama a `CabinetController.deleteLocalRegistration`; la pantalla sólo se cierra si la operación tiene éxito.

En HEAD, `lib/data/cabinets/cabinet_controller.dart:667–690`, esa función consultaba conjuntamente `syncing`, `refreshing`, `capturing`, `_removingLocal`, `_applyingGps`, `_photoLoads.isNotEmpty`, `_evidenceLoads.isNotEmpty` y `_submitting.isNotEmpty`. Cualquiera provocaba el texto exacto «Espera a que terminen las operaciones actuales.» Estas banderas y mapas son globales del controlador, no exclusivos del gabinete. Una descarga de fotografía de B bloqueaba eliminar A, aunque A fuera una copia completamente sincronizada.

No era necesariamente una transacción Hive activa ni una cola pendiente: también contaban consultas y descargas. El guardado usa `_serial`/`_writes`; su cola conserva continuidad después de excepciones. Las descargas limpian sus mapas con `whenComplete`; las banderas de sincronización y refresh se liberan con `finally`.

Otro defecto comprobado en código: el `finally` de `capture` esperaba `recoverPhotoGps()` antes de poner `capturing=false`. Si esa recuperación lanzaba una excepción, la bandera quedaba activada. Ahora la liberación está en un `finally` anidado.

El bloqueo global ya aparece en el commit `0a802d1a`, anterior a HAPI-3.1. No se atribuye su origen a hidrostáticas. No se inspeccionaron datos del teléfono: no se afirma qué petición concreta estaba en curso en el caso del usuario.

## Reproducción verificable
Se crearon dos expedientes sintéticos con recibos de servidor falso. Se dejó pendiente una descarga de B mediante un Completer y se solicitó eliminar A. Ejecutando el caso contra el controlador original de HEAD, falló exactamente con el mensaje reportado. El código corregido se restauró inmediatamente y el mismo caso pasó.

Comando del caso: `flutter test --no-pub test/cabinets/cabinet_local_deletion_busy_test.dart --plain-name 'other cabinet photo load does not block local deletion'`.

La reproducción no utilizó HTTP real, credenciales ni almacenamiento de campo. La versión original se probó sólo temporalmente sobre el archivo de este fix, que no contenía cambios HAPI previos.

## Corrección
Archivo principal: `lib/data/cabinets/cabinet_controller.dart`.

- `_activity` (línea 72) lleva operaciones por UUID con liberación garantizada mediante `finally`: escritura local, consulta, captura, historial, eliminación de fotografía y sincronización del expediente.
- `localDeletionBlocker` (línea 705) informa la causa específica. Las descargas se consultan por UUID, no por existencia de cualquier descarga.
- `deleteLocalRegistration` (línea 746) valida autorización, UID y condiciones antes de programar el borrado y nuevamente dentro del escritor serializado, antes de eliminar archivos. No permite nuevas operaciones sobre ese UUID mientras se elimina.
- Se conserva la exclusión mutua entre eliminaciones locales. Una eliminación de otro gabinete es un bloqueo breve deliberado; no se extiende a sus descargas o envíos.
- Se conservan operaciones sin sincronizar, formularios dirty, fotos locales sin verificar, capturas pendientes del journal y filas multimedia pendientes. El usuario recibe instrucciones para guardar, recuperar o sincronizar antes de eliminar.
- Se mantiene el tratamiento de ausencia remota confirmada, pero no se usa para descartar trabajo local pendiente.
- La sincronización omite un expediente ya retirado de su snapshot. Un refresh ya en curso no vuelve a introducir el expediente retirado durante ese mismo refresh. Un refresh posterior sí puede recuperar una copia que aún existe en servidor: es coherente con eliminación exclusivamente local.
- Se deja de cancelar el temporizador de reintentos por eliminar una copia local, para no suspender trabajo de otros expedientes.
- `capture` libera `capturing` incluso si falla recuperar GPS. La recuperación GPS omite el expediente que se está retirando.
- No se cambiaron endpoints, formatos Hive, migraciones, estados hidrostáticos ni colas compartidas. `_removeLocalDossier` mantiene sus comprobaciones de UUID/directorio y su eliminación exclusiva de filas pertenecientes al expediente.

Una copia pendiente de sincronizar no se elimina para evitar pérdida de datos. Si el servidor rechaza ese trabajo, el error debe resolverse explícitamente: esta corrección no lo descarta ni inventa confirmación remota.

## Archivos de este trabajo
1. `lib/data/cabinets/cabinet_controller.dart`.
2. `test/cabinets/cabinet_deletion_test.dart`.
3. `test/cabinets/cabinet_local_deletion_busy_test.dart` (nuevo).
4. Este informe.

Parte importante del diff del controlador corresponde a indentar el cuerpo existente de sincronización dentro de try/finally por expediente; no es una reescritura de su lógica.

Los dos tests antiguos de eliminación de copia se preparan ahora con recibo de sincronización antes de borrar. Su expectativa de aislamiento se mantiene. Se añadieron casos separados que exigen conservar un registro sin enviar, su formulario y fotografías; no se relajaron los resultados para ocultar un fallo.

## Pruebas
| Caso | Verificación | Resultado |
|---|---|---|
| Copia sin trabajo pendiente | Eliminación de copia confirmada conservando otro gabinete | PASS |
| Escritura propia activa | Store sintético detenido durante pull; borrado rechazado | PASS |
| Operación completada | Termina escritura/descarga; mismo borrado permitido | PASS |
| Excepción de operación | Fallo de escritura y de descarga libera actividad | PASS |
| Excepción al recuperar GPS | Captura no deja capturing activado | PASS |
| Otro gabinete | Descarga y sincronización de B no impiden retirar A | PASS |
| Sincronización pendiente | Registro, formulario dirty y archivo fotográfico conservados | PASS |
| Reinicio | Cierre/reapertura real de caja Hive temporal, nuevo controlador; pendientes preservados | PASS |
| Eliminación remota existente | Recibo perdido, conflicto de versión, UID y datos conservados | PASS |
| Regresión móvil/hidrostáticas | Suite local completa con fakes/fixtures | PASS |
| Certificación sobre teléfono | No ejecutada, fuera del alcance seguro solicitado | NOT RUN |

Comandos y resultados:
- `dart format` sobre los tres archivos del fix: correcto.
- `flutter analyze --no-pub`: **sin incidencias**.
- `flutter test --no-pub test/cabinets/cabinet_local_deletion_busy_test.dart test/cabinets/cabinet_deletion_test.dart`: **16 PASS, 0 FAIL** (10 casos nuevos).
- `flutter test --no-pub --reporter expanded`: **741 PASS, 0 FAIL, 1 omitida**. Incluye Gabinetes, Bases, cámara, almacenamiento e hidrostáticas con los cambios HAPI-3.1 presentes.
- Omisión: integración de Gabinetes condicionada a `CABINETS_TEST_SESSION` tras comprobar identidad TEST. No se proporcionaron credenciales ni se ejecutaron escrituras remotas.
- `git diff --check`: correcto.
- Verificación final SHA-256 de archivos preexistentes: **18 idénticos, 0 alterados**.

Incidencias intermedias documentadas: el caso contra HEAD falló deliberadamente para demostrar el defecto. Un test nuevo inyectaba la excepción antes de que el fake de almacenamiento empezara a esperarla; se ajustó el momento de inyección, conservando la exigencia de liberar el bloqueo. Se corrigieron avisos de estilo de llaves; el análisis final está limpio.

Logs locales de esta ejecución (temporales, no se incluyen en Git): `/tmp/cab-delete-reproduction.log`, `/tmp/cab-delete-targeted.log`, `/tmp/cab-delete-full.log`, `/tmp/cab-delete-analyze-final.log`.

## Límites y pendientes
- La corrección está en el checkout, sin commit ni APK instalada. Para observarla en Android hace falta compilar y actualizar de manera autorizada; aquí no se tocó el teléfono.
- Una operación propia realmente activa sigue bloqueando la eliminación hasta terminar o fallar. Las operaciones pendientes durables no se borran para «desbloquear».
- No se certificó el estado real del gabinete reportado, conectividad del teléfono ni despliegue remoto. El diagnóstico está respaldado por reproducción local determinista y código.
- No se modificó el mecanismo preexistente de eliminación de archivos por fallo de disco ni se amplió el alcance a una nueva transacción de borrado recuperable; se preservaron sus protecciones existentes.

## Estado
**COMPLETADA en código y regresión local.** Validación física/actualización de APK no realizada. Cambios listos para revisión, HAPI-3.1 preservado.

## Apertura del informe
Archivo verificado. VS Code: abierto mediante `code -r` (salida 0).
