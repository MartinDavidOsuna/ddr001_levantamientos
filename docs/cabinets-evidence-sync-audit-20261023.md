# Auditoría de evidencia y sincronización — 23 octubre 2026

## Base y alcance

Rama móvil `fix/cabinet-evidence-sync-audit`, base `f5cedb8ab50a097c9e3f93bd8c8baf2f3c725301`.
El commit `320c031` conserva exactamente el trabajo local de la APK 1.5.18+29 antes de las correcciones; su worktree original se mantiene intacto. `origin/main` móvil era `a288294` y no contenía todos esos cambios. El PR incluye esa base de campo para que la corrección sea integrable.

API main actualizada por fast-forward a `6317db5d42abfa974fdd81b5a7d73603de893f45`, coincidente con `/version` productivo. La prueba HTTP ejecutó ese contrato en `http://127.0.0.1:3003/api/v1`, perfil `construction-test`, identidad SQL `DDR001_Hidrantes_TEST` / `WIN-5RQE8N8NQ9V`, almacenamiento `.storage/construction-test`. Sin despliegue, migraciones ni escrituras productivas.

## Hallazgos y correcciones

- La API permite a residentes consultar fotos de otros residentes. La app no consultaba automáticamente el inventario y condicionaba la descarga a poder editar. Ahora consulta todas las páginas al abrir el expediente, incluso borrador, sin exigir propiedad de pendientes. Conserva actor, operaciones, borrador, archivos y eliminaciones pendientes.
- Primero se persisten metadatos; miniaturas y originales se descargan a demanda. Los originales se verifican por SHA-256. Las fotos remotas no se suben como capturas locales ni se consideran verificadas por haber leído su inventario. Los comandos que las referencian siguen verificándolas en servidor.
- El inicio sólo contaba la cola de bases. Ahora muestra también expedientes pendientes de gabinetes; el reintento atiende ambos módulos. Una captura todavía sin comando no se presenta como sincronizada.
- No se permite guardar el cierre de piezas mientras el registro sigue en borrador. La captura permanece local y se indica regresar a Registro. No se fabrican cierres para los borradores antiguos.
- Se distinguen conexión, timeout y HTTP, y se decodifican problemas JSON recibidos como bytes. Se conserva diagnóstico mínimo (tipo, estado HTTP, ruta, request ID y fecha), sin tokens/cuerpos/cabeceras sensibles. Se mantiene recuperación por operationId antes de reenviar resultados ambiguos.
- Se detectó en TEST una interrupción SQL durante autenticación que la API clasificó como 401; el PR API `fix/auth-database-unavailable` cambia ese caso a 503 reintentable y conserva 401 para identidad revocada/token inválido. No es prueba de que explique todos los fallos productivos.

## Evidencia productiva, sólo lectura

Ocho expedientes, 43 operaciones y 25 fotos al auditar. Cuatro borradores (00001, 00004, 00005, 00006) tenían fotografías y únicamente `register`, sin `registration_close` recibido. Dos (00002 y 00003) estaban validados; 99997 tenía instalación guardada, sin cierre; 99999 era incompleto con tres piezas explícitamente ausentes. No existían `installation_close` o `final_review` exitosos. No se transformaron esos datos.

El historial de integridad tenía 25 comprobaciones positivas y 48 objetos de almacenamiento presentes/verificados para 24 fotos; eso no certifica disponibilidad actual del NAS. En el Pixel productivo, la descarga explícita de las cuatro fotos del 00002 funcionó desde otro residente. Los pendientes de los cuatro borradores deben revisarse en los teléfonos originales antes de reenviarlos.

## Validación

- `flutter analyze --no-pub`: sin incidencias.
- `flutter test --no-pub`: 256 pasan, una prueba HTTP omitida sin fixture; ejecutada separadamente y aprobada.
- HTTP real Dart/Hive → API → SQL TEST/archivos: `AQ26102249`, expediente `22c512d4-ef67-46a2-b914-ab8981344075`, Entregable versión 12, 41 piezas, seis fotos verificadas y 12 operaciones. Incluye reenvío idempotente, invalidación de aprobación y resolución de revisión negativa. Datos y estado local coinciden con API/historial.
- 13 peticiones de comandos: mediana 684 ms, máximo 1771 ms en esta prueba. No reproduce latencia NAS ni prueba una solución de rendimiento productivo.
- Pruebas adicionales: inventario de 101 fotos paginado, pendientes de otro actor conservados, caché/recuperación de archivo faltante, hash incorrecto rechazado, contratista sin acceso, imposibilidad de saltar Registro, problemas JSON binarios y distinción de errores. La suite existente cubre recuperación, conflictos, sesión, colas, permisos y regresión de bases.

## Reproducir TEST

1. En el API indicado, configurar `.env.construction-test.local` con perfil TEST/DB TEST y almacenamiento local. Iniciar con `NODE_ENV=test TEMP_CLEANUP_ENABLED=false ARCHIVE_WORKER_ENABLED=false GIT_COMMIT=<HEAD de 40 caracteres> npm run dev:construction-test`. Comprobar el preflight y `/api/v1/version`.
2. Desde la app: `API_CHECKOUT=/ruta/absoluta/api /ruta/absoluta/api/node_modules/.bin/tsx tools/prepare_cabinet_audit_test.mts`. El script comprueba identidad antes de crear dos residentes, sesiones y una base sintéticos. Escribe `.test-cabinets/session.json` con modo 0600; no compartir ni versionar ese archivo. Conserva los datos como evidencia TEST.
3. `CABINETS_TEST_SESSION=.test-cabinets/session.json flutter test test/cabinets/cabinet_http_integration_test.dart`. Resultado sin credenciales en `.test-cabinets/result.json`. Usar un fixture nuevo por ejecución del recorrido que escribe.
4. Sólo en emulador o dispositivo dedicado a TEST, los builds Android debug usan exclusivamente `com.aquafim.ddr001levantamientos.test`, etiqueta `AQ NH DDR001 TEST`; release conserva identidad/firma anteriores. Crear un JSON privado de defines con APP_ENV=test, API_BASE_URL=http://127.0.0.1:3003/api/v1, CABINETS_QA_UID del fixture y CABINETS_QA_SESSION (JSON textual de otherSession con name/email/phone/kind=field). Ejecutar `adb reverse tcp:3003 tcp:3003` y `flutter test --no-uninstall integration_test/cabinet_shared_evidence_test.dart -d <serial> --dart-define-from-file=<archivo privado>`. La prueba verifica paquete/URL/entorno antes de guardar sesión. Es obligatorio `--no-uninstall`: el ejecutor de Flutter tiene limpieza destructiva activada por defecto. Compilar antes y verificar el package ID del APK y del ejecutor; no volver a ejecutar esta prueba en un dispositivo de campo.

## Garantías y pendientes

No hay migración destructiva: se agregan campos opcionales al documento Hive existente. Las capturas se guardan antes de red; las imágenes descargadas quedan consultables sin conexión. Miniaturas/originales todavía no descargados requieren red. Se conservan atribución y restricciones ante cambio de sesión; leer evidencia compartida no autoriza enviar pendientes ajenos. Sin promesa de ejecución permanente con app cerrada.

Antes de liberación: revisar los journals de los teléfonos con borradores; reproducir el error productivo con request ID/hora/HTTP y correlacionar logs API/SQL/NAS; validar latencias de almacenamiento real. No aumentar timeouts ni aprobar/inventar respuestas para ocultar fallos. La corrección API no requiere migración SQL. Integración y despliegue productivos siguen pendientes de revisión de los PR.

## Prueba Pixel e incidente de preservación

La segunda ejecución de la prueba en Pixel 7 Pro aprobó: sesión de otro residente, inventario automático de seis fotos, originales verificados y lectura desde caché sin conexión. La primera falló por indisponibilidad SQL durante autenticación.

Sin embargo, la comprobación posterior mostró que Android ya no enumeraba **ni `com.aquafim.ddr001levantamientos` ni su variante `.test`**, tampoco con `pm list packages -u`. Se suspendieron inmediatamente las pruebas y no se reinstaló nada. No se puede afirmar preservación de los datos locales del Pixel.

El ejecutor Flutter instalado tiene `uninstall` activado por defecto. `IntegrationTestDevice` obtiene `_applicationPackage` antes de compilar y lo usa para desinstalar al terminar. La primera ejecución partió de un worktree sin APK compilada, cuyo manifiesto/base identificaba el paquete productivo; las sesiones Android confirman que las APK instaladas sí fueron `.test`. La combinación es consistente con la retirada del paquete productivo al finalizar la primera prueba y de TEST al finalizar la segunda. Los logs sin verbose no contienen el comando exacto de desinstalación; por tanto la atribución es probable, no una captura directa del comando.

Se informó al usuario. No se ejecutó uninstall/clear/reset explícitamente, pero la limpieza implícita debió desactivarse. No afirmar que reinstalar recupera pendientes o fotos privadas: esa recuperación no está demostrada. Los datos productivos del servidor no fueron modificados. Queda pendiente evaluar respaldos existentes y acordar recuperación del dispositivo; no usarlo para nuevas pruebas. Este incidente bloquea considerar certificada la preservación del dispositivo.
