# Integración 1.5.1+12 — 2026-10-06

Fuente remota consultada con `git fetch --all --prune`: origin/main
`0b78ac7`. Ya es ancestro de feat/ddr001-cabinets-mobile.

Todas las ramas remotas están incluidas por ascendencia. Las ramas locales
fix/app-zero-loss-and-resilience-certification (26052e1) y
release/levantamientos-production-branding (5525592) divergen históricamente,
pero sus funcionalidades fueron reconciliadas en d6550a5 e incorporadas a
main por 3f3a844. La comparación de 5525592 con d6550a5 sólo presenta
ajustes de documentación, login y versión; no falta resiliencia ni branding.
No se fusiona nuevamente ese historial antiguo.

La rama feature/map-coordinates-1.4.1 conserva su trabajo local original;
mapas y galería están integrados en c565e11. No se altera ese worktree.

Esta versión incorpora las protecciones descritas en
[prevención de errores](human-error-prevention-20261006.md).
El ajuste asociado de API para conservar piezas compatibles sigue en
feat/ddr001-cabinets del repositorio API y requiere integración coordinada.

Artefacto: `dist/DDR001-Levantamientos-1.5.1+12-TEST.apk`.
Entorno TEST, API `http://127.0.0.1:3003/api/v1`, conexión por adb reverse,
paquete aislado `com.aquafim.ddr001levantamientos.cabinetstest`, build debug.
No es una publicación productiva. No contiene credenciales de pruebas.

Se valida con flutter analyze, flutter test, compilación Android y
comparación SHA-256 entre el APK local y su copia en Downloads del Pixel.
La integración de main es local mediante fast-forward, sin push.
