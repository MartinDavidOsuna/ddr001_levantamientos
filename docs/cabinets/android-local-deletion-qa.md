# ANDROID-1: eliminación local en Android aislado

El ejecutor `test/cabinets/android_deletion_qa.dart` usa el `CabinetController`
real y Hive en almacenamiento privado de Android. El backend es el fake de la
regresión, no una API. Nunca importar este entrypoint desde `lib/main.dart`.
No utiliza sesiones, fotos ni gabinetes operativos. Los bytes fotográficos son
un PNG sintético mínimo: esta certificación verifica preservación, no cámara.

## Build

Sin modificar dependencias, generar un JSON de defines temporal con:

- APP_ENV: `test`
- CABINET_DELETION_QA: `true`
- HYDROSTATIC_SYNC_ENABLED: `false`
- CABINET_QA_CATALOG: contenido JSON compacto de
  `test/cabinets/fixtures/catalog-46b0265.json`, como cadena.

```sh
ORG_GRADLE_PROJECT_cabinetDeletionTest=true flutter build apk --debug --no-pub \
  -t test/cabinets/android_deletion_qa.dart \
  --build-name=1.5.24-qa.android1 --build-number=36 \
  --dart-define-from-file=/tmp/android1-build-defines.json
```

El opt-in Gradle selecciona `.cabinettest`, nombre DDR001 GABINETES QA, y el
manifest QA sin INTERNET ni ACCESS_NETWORK_STATE. Rechaza release y selección
simultánea con hydrostaticTest. El entrypoint comprueba package exacto, debug,
APP_ENV y bandera QA antes de abrir Hive. También rechaza HttpClient.
Las configuraciones normal e hidrostática conservan sus identidades.

## Instalación y ejecución seguras

Inspeccionar el APK con aapt/apksigner y comprobar package/version/firma. Si ya
existe `.cabinettest`, verificar firma y versionCode antes de `adb install -r`.
Nunca desinstalar ni limpiar almacenamiento para instalar. Nunca instalar este
artefacto sobre `.ddr001levantamientos` o `.hydrotest`.

1. Abrir `.cabinettest` y pulsar EJECUTAR PRUEBAS 1–5 mediante ADB o manualmente.
2. El ejecutor crea registros sintéticos separados con UID de prueba validado
   por `cabinetUid`, y comprueba los cinco casos mediante aserciones explícitas.
3. Al mostrar REINICIO PREPARADO conserva un fetch pendiente en memoria sobre
   un expediente de prueba. El checkpoint se escribe con flush antes de salir.
4. Cerrar el proceso **únicamente de `.cabinettest`** y volver a abrirlo; no
   reiniciar el teléfono ni detener paquetes operativos.
5. Pulsar VERIFICAR REINICIO. Se comparan documentos completos y SHA-256 de B y
   del registro pendiente. Se comprueba que éste sigue protegido y que la copia
   limpia se puede eliminar: el lock de memoria no sobrevivió al proceso.

Los resultados y el checkpoint permanecen en `files/android1-synthetic/` del
paquete QA. No se ejecuta Harness.close ni limpieza del directorio al terminar.
El primer lote se protege contra repetición si ya existe un checkpoint. No
volver a ejecutar el caso 6 después del PASS: su expediente limpio ya se retiró.
Para repetir toda la campaña se debe diseñar un nuevo conjunto explícito de
fixtures sin limpiar datos anteriores.

## Alcance

Son pruebas físicas instrumentadas desde una pantalla de certificación. Ejecutan
el controlador, colas y archivos reales en Pixel; las llamadas remotas son
simuladas. No certifican navegación completa de la pantalla operativa, API TEST,
producción, ni sincronización hidrostática remota. HAPI-3.1 permanece respaldada
en la misma rama y cubierta por la suite local; su envío está deshabilitado en
esta APK. No se ha instalado una actualización de la aplicación operacional.
