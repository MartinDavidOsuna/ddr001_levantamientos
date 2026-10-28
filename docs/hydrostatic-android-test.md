# Android aislado para certificación hidrostática (M7)

Esta variante es exclusivamente sintética, debug y local. No certifica presión hidráulica.
No se debe instalar sobre la app operativa ni copiarle archivos de campo.

## Construcción

Desde el worktree de hidrostáticas, con Flutter y Android SDK existentes:

```sh
ORG_GRADLE_PROJECT_hydrostaticTest=true flutter build apk --debug --no-pub \
  -t lib/main_hydrostatic_test.dart \
  --dart-define=APP_ENV=test --dart-define=HYDROSTATIC_QA=true
```

Verificar el APK con `aapt dump badging` y `aapt dump permissions` ANTES de instalar:
package `com.aquafim.ddr001levantamientos.hydrotest`, nombre `DDR001 HIDRO TEST`,
sin permiso INTERNET, sin sharedUserId. Guardar SHA-256 del artefacto.
El guard Dart rechaza otro package, ambiente, bandera o build no debug.
El flag Gradle rechaza release. La configuración productiva no cambia.

Seleccionar explícitamente el serial ADB, sin publicarlo. Primero inventariar paquetes,
versiones y pendientes por métodos de lectura. Si los pendientes no se pueden verificar,
no tocar la instalación operativa. Instalar por primera vez el paquete QA distinto;
para actualizarlo usar `adb -s "$TEST_DEVICE_SERIAL" install -r <apk>` únicamente
tras verificar que el APK y paquete instalado son `.hydrotest`. Nunca desinstalar,
usar pm clear, copiar Hive operativa, cambiar la hora global o rootear.

## Datos y controles

El entrypoint independiente evita bootstrap de autenticación/sync; inyecta un actor
sintético persistente, tres gabinetes sintéticos y usa el controlador/repositorio real.
No concede permisos a usuarios operativos: su acceso sólo existe en este proceso QA.
No importa `main.dart` ni está referenciado por él. Se conserva almacenamiento privado
propio y cámara/GPS reales. HTTP Dart falla explícitamente y Android carece de INTERNET.
El servicio debug de Dart puede registrar errores de socket: son esperados por ese bloqueo.
No habilitar INTERNET para depurarlo; usar ADB.

`AUDITORÍA TEST` escribe `files/qa-audit.json`: identificadores sintéticos, estados,
SHA-256 y verificaciones; no incluye coordenadas ni secretos. Exportar sólo esa auditoría
sanitizada. El contador HTTP es por proceso, no una captura completa de tráfico.

`+31 MIN TEST` adelanta únicamente el reloj inyectado; bloqueado con pruebas ACTIVE.
No cambia la hora Android. Usar sólo para un intento terminado pendiente de resultado.
`RELOJ REAL` restaura el offset QA para nuevas capturas/GPS. No modifica timestamps
históricos ni revive intentos descartados. No tomar fotos/GPS con offset artificial.
No confirmar videos sintéticos en grupos operativos; VIDEO ENVIADO sólo ejercita la
persistencia local de la declaración. La eliminación de desarrollo sigue deshabilitada.

Los originales quedan en `<ApplicationSupport>/hydrostatic/<testId>/evidence/` del
paquete TEST. No exportar fotos personales. Force-stop sólo del paquete TEST para
recuperación; no reiniciar el Pixel si hay trabajo de campo no verificable.
