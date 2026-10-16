# Checklist y catálogo v2 — 2026-10-15

Base de rama: origin/main `a2882944539df0b56e169bc0b70bd7b12e5b9ab3`. Rama: `feat/cabinet-checklist-display-names`.

La pantalla de piezas utiliza `displayName ?? description` del snapshot del gabinete. La identidad de captura, evidencia y sincronización sigue siendo `code`. La app no lee XLSX ni contiene objetivos de producción. La descripción original permanece en el snapshot; ningún serial se convierte a número.

El catálogo descargado se guarda íntegro en Hive por versión. Los nuevos gabinetes usan la versión actual descargada. Un expediente iniciado conserva su `catalogVersion`, nombres y códigos tras descargar otro catálogo, reiniciar o corregir su modelo. No se borra Hive ni se reescriben expedientes.

Fuente del fixture v2: catálogo generado por API desde `A3-A2-A1-A4 - HIDRANTES PARCELARIOS - Material para codigos QR(1).xlsx`, SHA256 `1b1bb2792efc01246ab0ff5ed78a7b8912c884d413b8b2be7fb5015eafec8eb5`. Versión `ddr001-cabinets-20261015-v2`; el fixture antiguo permanece para regresión. Las ocho variantes conservan instancias y reglas de serie. Los extras de automatización ausentes del Excel usan su descripción histórica.

Validación: `flutter test` 227 aprobadas, 1 integración HTTP omitida por configuración; `flutter analyze` sin incidencias. Incluye QR, checklist, fotografías, series, sync, bases, Hive/reinicio y render de nombre visible. La integración real del contrato Field se ejecuta en el PR API contra SQL TEST.

Versión preparada: 1.5.3+14. APK firmado de TEST compilado con `APP_ENV=test` y `API_BASE_URL=http://127.0.0.1:3003/api/v1`. Requiere API TEST local y, cuando se conecte Pixel, redirección USB correspondiente. No se instaló, distribuyó ni probó físicamente: el usuario indicará cuándo conectar Pixel. No representa certificación productiva.

Dependencia: integrar primero API `feat/cabinet-catalog-display-names-production` con migración/rebuild; ningún despliegue ni merge automático forma parte de esta entrega.

API requerida: https://github.com/MartinDavidOsuna/ddr001_api/pull/19.
APK local: `dist/DDR001-Levantamientos-1.5.3+14-TEST.apk`; SHA256 `3262622b3b129930e21510706cddf0f424d6e4558a851bfac8c5e194415099c7`. Firma APK v2 verificada; versionCode 14/versionName 1.5.3. No incluye el Excel en runtime.
