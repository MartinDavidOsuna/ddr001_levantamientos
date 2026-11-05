# FIX — Acceso operativo a Pruebas Hidrostáticas

Repositorio: `/Users/martino/DEV/ddr001_levantamientos`. Rama: `release/hydrostatic-rc1`.

## 1. Causa exacta

El menú operativo está construido en `HomePage`; las tres acciones reportadas pertenecen a esa pantalla. La pestaña inferior LEVANTAMIENTOS usa `SurveysPage` para el listado de bases. No existe un router separado para hidrostáticas: se usa `Navigator.push` y `MaterialPageRoute`.

El botón ya existía, pero `if (hydrostatic?.allowed == true)` lo eliminaba silenciosamente del árbol de widgets. `allowed` deriva de la identidad autorizada; el adaptador exige sesión field, perfil residente del mismo usuario y permiso de Gabinetes guardado. Las tarjetas de Gabinetes usan `eligible`, que sólo verifica sesión/rol/identidad, sin exigir ese permiso guardado. Por eso pueden aparecer las tres tarjetas y faltar Hidrostáticas.

La autorización de Gabinetes se guarda tras descargar su catálogo. Su ausencia o revocación bloqueaba el acceso y además ocultaba el botón. Una caída temporal de API conserva un permiso previamente guardado; no debe interpretarse como una nueva autorización si nunca existió. La corrección conserva esta distinción.

**Comprobación RC2:** la APK local `dist/hydrostatic-express/ddr001-1.5.25-rc.2-40.apk` tiene package original y versión 40. Las secciones `.text`, `.rodata` y `.note.gnu.build-id` de su biblioteca arm64 coinciden con el AOT de `.dart_tool/flutter_build/348320a8e737f62c7e7615066580b391/arm64-v8a/app.so`. El kernel de ese build, fechado 2026-11-03, contiene literalmente la condición que oculta el botón. El binario también contiene `hydrostatic-list`, el título y el mensaje de autorización original. El defecto estaba en RC2; el módulo no era exclusivo de QA.

No se leyó el dispositivo del usuario: no se afirma cuál permiso/sesión concreta tenía almacenado. La causa demostrada es el ocultamiento por autorización; RC3 expone el motivo concreto en la aplicación.

## 2. Archivos y líneas responsables

- Antes del fix, `lib/features/home/home_page.dart:100`: condición de visibilidad; líneas 107–111: ruta existente.
- `lib/data/cabinets/cabinet_controller.dart:94`: diferencia entre `eligible` y `allowed`; líneas 210–235: catálogo y autorización persistida.
- `lib/main.dart:50`: adaptador con `cabinetAuthorized: () => cabinets.allowed`; línea 62: único Provider del controlador.
- `lib/core/hydrostatic/hydrostatic_bootstrap.dart:37`: fábrica productiva; línea 61: apertura del almacén local; línea 22: gates de sincronización.
- `lib/features/hydrostatic/hydrostatic_pages.dart:68`: la pantalla recupera el mismo controlador; línea 79: inicialización.
- Corrección: `lib/features/home/home_page.dart:100`, `lib/features/hydrostatic/hydrostatic_controller.dart:98`, `lib/data/hydrostatic/hydrostatic_access_adapter.dart:31`.

## 3. Corrección

PRUEBAS HIDROSTÁTICAS permanece visible. La tarjeta muestra la explicación de sesión, rol, permiso local ausente o controlador no disponible. Al pulsarla sin autorización muestra el motivo y no navega ni abre almacenamiento. Con autorización navega al `HydrostaticListPage` existente mediante `hydrostatic-list`.

Se conserva el flujo completo existente: identificación QR/serie, preparación, ejecución, fotos, fugas, APROBADO/FUGA/DESCARTADA, historial y estado de sincronización. No se duplican controladores ni se cambia el flujo de captura. No se alteraron API, Dashboard, SQL, esquemas ni datos.

## 4. Permisos y funcionamiento local

Se mantiene exactamente la combinación de requisitos de autorización anterior. Contratistas, administradores y superadministradores no obtienen acceso por ver la tarjeta. Se conserva la comprobación de sesión persistida y el bloqueo de rutas ante cambio de identidad.

El renderizado y la entrada local no consultan la API. Un residente con permiso guardado puede abrir el módulo sin conexión. Si nunca tuvo permiso guardado, se indica que debe conectar y actualizar Gabinetes para verificarlo; no se le concede permiso por el solo hecho de tener rol residente. Los gates de sync no controlan la visibilidad.

## 5. Pruebas

- `flutter analyze`: sin incidencias; repetido tras el último test añadido.
- `flutter test`: 758 aprobadas, una omitida por requisito preexistente de `CABINETS_TEST_SESSION`; sin fallos.
- Suite final `test/hydrostatic/menu_test.dart`: 6 aprobadas, incluida una prueba adicional agregada después de la ejecución completa.
- Nuevas comprobaciones: visibilidad; ruta real; inicialización con fábrica productiva y adaptadores de cámara/GPS; identificación QR/serie; residente offline; caída temporal de API con permiso conservado; denegación a contractor/admin/superadmin; permiso de Gabinetes ausente con motivo visible, sin navegación ni apertura del repositorio.
- Se actualizó el test antiguo que esperaba ocultamiento para exigir botón visible **y** bloqueo efectivo. No se retiró la comprobación de autorización ni se relajaron expectativas de captura.
- Se usaron directorios temporales de pruebas y solicitudes interceptadas. No se hicieron solicitudes a producción ni se usaron tokens reales.

## 6. Regresión

La suite completa incluyó Gabinetes y pruebas hidrostáticas: repositorio, ejecución, resultados, fotos, fugas, QR, GPS, journal/recuperación, sincronización documental y de evidencias. El test nuevo comprueba además que permanecen las tres acciones de Gabinetes/Base. El gate de sync productivo conserva su test contractual de doble habilitación y transporte permitido.

La prueba remota omitida requiere preparación y credenciales TEST; no se inventaron credenciales ni se ejecutó contra producción. No se instaló ni se realizó prueba física en el teléfono.

## 7. Commit y preservación del checkout

Commit local exclusivo: `783ed579b88ae341ffa2175df7fd547b6ef75e77` — `fix(hydrostatic): expose operational menu with explicit access reasons`.

Incluye sólo menú, explicación de permisos, tests y versión/configuración de build RC3. No se hizo push, merge ni worktree. Los cambios previos de `android/app/build.gradle.kts`, `test/cabinets/harness.dart` y los archivos no rastreados permanecen fuera del commit. El wrapper de build usa el Gradle comprometido y restaura el overlay QA previo byte por byte al finalizar.

## 8. APK y configuración productiva

[Descargar APK RC3](../dist/hydrostatic-menu/ddr001-1.5.25-rc.3-41.apk) — 77,406,917 bytes.

Build: `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' python3 tool/build_hydrostatic_rc.py`.

Resultado: **BUILD SUCCESSFUL**, 1m 41s; 518 tareas. Se reutilizó el wrapper release documentado y la firma existente. Entrypoint `lib/main.dart`; arquitecturas ARM32, ARM64 y x86_64.

Configuración explícita del build, conservada en el script del commit:

- `APP_ENV=production`
- `API_BASE_URL=http://cifra.aquafim.com:3002/api/v1`
- `HYDROSTATIC_SYNC_ENABLED=true`
- `HYDROSTATIC_PRODUCTION_SYNC_ENABLED=true`

El endpoint coincide con `AppConfig.productionHttpApiBaseUrl` y se comprobó dentro del AOT resultante. Es el HTTP heredado autorizado por el gate existente; no se modificó transporte ni servidor. No se habilitaron fixtures, entrypoints QA ni eliminación de desarrollo. La configuración no contiene claves ni tokens. Sync conserva las validaciones existentes; la compilación no se presenta como prueba de envío al servidor.

Se comprobaron en el APK el nombre de ruta y el nuevo mensaje de permiso, además de versión/package. El Gradle QA preexistente quedó restaurado idéntico a `build/hydrostatic-menu-preserved-build.gradle.kts`. Las advertencias de herramientas/plugins Gradle/Kotlin no impidieron compilar.

## 9. Versión

- `versionName`: `1.5.25-rc.3`.
- `versionCode`: **41**, superior a RC2 **40**.
- Package: `com.aquafim.ddr001levantamientos`.
- `pubspec.yaml`: `1.5.25-rc.3+41`.

## 10. Firma

`apksigner verify --verbose --print-certs`: **Verifies**, firma APK v2 válida, un firmante RSA de 4096 bits.

Certificado SHA-256: `780f516576d98fff8edaf34be7af6c4488dd8fd57a2c97500c9ff07e60195544`.

Coincide exactamente con el certificado de la APK RC2 local. No se generaron ni copiaron claves; se utilizó la configuración original de firma. La firma del dispositivo instalado no se leyó en esta intervención.

## 11. SHA-256 y evidencias

APK RC3: `f62f6b251424f20639e9c650cc9e7e1f232b73fcec261e36ad0c7533dbafa958`.

APK RC2 de referencia: `f7dc9c980b6d90492b43cfc101596e683843f64681872afc7c98154dc252b67d`.

[Carpeta de evidencias](./FIX-HYDROSTATIC-MENU_2026-11-04_12-37-49_evidencias/): logs de pruebas, análisis, build, comparación AOT RC2, badging y certificados públicos. También contiene copia del script de compilación con sus defines públicos. [Checksum RC3](../dist/hydrostatic-menu/ddr001-1.5.25-rc.3-41.apk.sha256).

## 12. Actualización conservadora

1. Verificar el SHA-256 del archivo recibido y que el dispositivo tenga el package original. Para la actualización esperada, confirmar RC2 (40) y el mismo certificado indicado arriba. Si la versión instalada es mayor o igual a 41 o la firma difiere, detenerse; no resolverlo desinstalando.
2. Cerrar la aplicación normalmente. Abrir esta APK en Android y elegir **Actualizar** sobre la aplicación existente. Si se usa ADB en una intervención autorizada posterior, usar `adb install -r <APK>`; no se ejecutó aquí.
3. No desinstalar, borrar almacenamiento/caché, usar `pm clear`, eliminar carpetas, editar Hive/colas/journals ni ejecutar migraciones.
4. Abrir la app y comprobar versión 41, sesión y datos previos. En el menú operativo comprobar PRUEBAS HIDROSTÁTICAS. Con residente autorizado abrir el flujo existente; con permiso ausente leer el motivo y verificar autorización mediante Gabinetes sin manipular datos locales.
5. Comprobar historial/fotos/colas previos y acceso local sin conexión. Al recuperar conexión, la sincronización productiva permanece habilitada y sigue las reglas existentes.

No se instaló la APK, no se desinstaló la aplicación ni se accedió a datos del teléfono. No se alteraron Hive, fotografías, journals, colas o sesiones de usuario, ni producción. Este fix no incluye migraciones. La persistencia y recuperación se verificaron mediante regresión automatizada; la comprobación física posterior a actualizar queda a cargo del operador.
