# Verificación posterior al despliegue de API PR 26 y 27

Fecha: 23 octubre 2026. Commit integrado y desplegado: `e6f59546069a876de4d985be5c6e1da4e1fc077c`.

## Producción: lectura y salud

- GitHub confirma PR 26 y 27 integrados. `/api/v1/version` informa ese mismo commit, ambiente production, build `2026-10-23T22:40:28.137Z`.
- `/health/ready`: SQL, almacenamiento y configuración correctos.
- `/health/storage`: archivo disponible, cero objetos pendientes, cero errores, 76.270 objetos verificados al consultar. Es una comprobación puntual, no certificación de cada archivo ni de estabilidad permanente.
- El catálogo sin sesión responde 401, manteniendo la protección. No se disponía de una sesión productiva autenticada para descargar catálogo/fotos directamente; esa comprobación se hizo en TEST con dos residentes.
- Consulta SQL de sólo lectura verificó `DDR001_Hidrantes_Prod`, servidor `WIN-5RQE8N8NQ9V`: ocho gabinetes, 43 operaciones, 25 fotos. Se conservan los cuatro borradores, dos validados, 99997 con instalación guardada sin cerrar y 99999 incompleto. Las versiones de catálogo históricas siguen v1/v2; no hay migración silenciosa.
- Sin comandos de escritura, fixtures, migraciones ni cambios de estado productivos. Sin acceso o cambios al Pixel.

## Mismo commit contra TEST real

API local `http://127.0.0.1:3003/api/v1`; perfil `construction-test`; SQL `DDR001_Hidrantes_TEST` / `WIN-5RQE8N8NQ9V`; almacenamiento `.storage/construction-test`; tareas automáticas desactivadas. Identidad verificada antes de generar datos sintéticos.

`CABINETS_TEST_SESSION=<fixture privado> flutter test --no-pub test/cabinets/cabinet_http_integration_test.dart` aprobado en 26 segundos:

- Gabinete sintético `AQ26-24344-6`, UUID `35b79353-a64b-476a-a457-858eaf391b0a`, A4 automatizado, catálogo v3.
- Captura offline en Hive y sincronización por HTTP real: registro, revisión/validación de piezas, fotos/verificación, instalación y revisión final.
- Resultado Entregable, versión 12, **45 piezas**, seis fotos verificadas, 12 operaciones de historial.
- Reenvío idempotente no duplica operaciones. Corrección invalida aprobación; revisión negativa y resolución posterior vuelven a Entregable. Estado/datos locales coinciden con detalle e historial de la API.
- Segundo residente consulta inventario y descarga las seis fotos originales por HTTP; cada SHA-256 coincide con el informado por servidor y el actor de las imágenes es otro usuario.
- 48 peticiones registradas, sin HTTP 5xx; 13 comandos, mediana 1.035 ms, máximo 3.095 ms. No extrapolar a latencia NAS productiva.

Se corrigió el preparador de fixtures para validar rutas desde el checkout API y escribir su archivo privado en una ruta absoluta. La prueba ya compara la cantidad con el catálogo versionado en lugar de asumir las 41 piezas de v2, y añade la consulta real del segundo residente.

## Regresión

- API integrado: 1.074 pruebas unitarias aprobadas, dos omitidas; type-check, lint y build aprobados. Incluye clasificación 503 de fallos SQL y las ocho variantes del catálogo.
- App: 256 pruebas aprobadas, una HTTP omitida en la suite general pero ejecutada separadamente y aprobada; analyze sin incidencias.
- No se volvió a compilar/instalar en el Pixel. No se realizaron capturas reales de cámara/GPS; las evidencias del recorrido TEST son sintéticas. No es certificación de interfaz/dispositivo ni E2E con escrituras productivas.

## Pendientes para afirmar funcionamiento productivo completo

El PR móvil #9 sigue abierto en borrador: producción API actualizada no distribuye por sí sola la corrección móvil de galerías, reintentos e indicadores. Los borradores previos necesitan revisar sus journals y archivos en los teléfonos de origen; no deben cerrarse ni aprobarse por inferencia. La recuperación del Pixel sigue pendiente según el informe anterior. Hace falta validar la app aprobada en un dispositivo exclusivamente TEST y después una liberación coordinada, conservando datos. No se puede prometer ausencia de fallos a partir de estas comprobaciones puntuales.
