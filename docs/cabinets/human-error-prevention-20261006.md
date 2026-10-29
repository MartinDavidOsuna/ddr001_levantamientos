# Prevención y corrección de errores humanos — 2026-10-06

Implementación móvil en `feat/ddr001-cabinets-mobile`; ajuste coordinado en API
`feat/ddr001-cabinets`. Cambios sin commit/push ni despliegue productivo.

## Comportamiento

- Doble envío: botones con estado ocupado, exclusión mientras se ejecuta una acción,
  protección de solicitudes idénticas y cierre de registro idempotente local.
  Las operaciones diferentes siguen su cola; no se deduplican ediciones distintas.
- Identidad: al completar registro y emitir dictamen se muestra UID/modelo/base/cuenta
  y se pide confirmación explícita. Se recuerda comprobar la placa física.
- Base: confirmación con identificador, cuenta y coordenadas; aviso de falta de datos
  geográficos o distancia mayor que `max(50 m, precisión base + precisión GPS)`.
  Es un umbral de advertencia móvil, no una regla de rechazo del dominio backend.
- GPS: guardar/cerrar instalación desde UI requiere captura con antigüedad máxima
  de 15 minutos. El borrador y las fotos antiguas se conservan; no se cambia su fecha
  ni se reutiliza una ubicación antigua como si fuese recién capturada.
- Dictamen: confirmación separada por acción, motivo y contexto; comprobación física
  debe confirmarse de nuevo después de 15 minutos o al editar piezas/instalación.
  Una solicitud enviada limpia las declaraciones locales del siguiente dictamen.
- Modelo: diálogo desplazable, adaptable a texto grande/teclado, motivo de 3–2000
  caracteres y borrador del diálogo persistido por usuario. Previsualiza cuántas piezas permanecen
  y cuántas dejan de aplicar. Reinicia el checklist y exige revalidación.
- Compatibilidad de piezas (móvil y API): correspondencia unívoca por clave de producto,
  descripción, posición física y política de serie. Remapea el código al nuevo catálogo;
  conserva presencia, serie, observaciones y evidencia. Los casos ambiguos no se mapean.
  Fotos e historial permanecen; no se agregaron columnas ni migraciones SQL.
- Series: texto con ceros iniciales conservados, espacios normalizados y sin autocorrección;
  ayudas para 0/O y 1/I. Series repetidas dentro del expediente generan advertencia con
  confirmación de placas antes de validar. No se impone unicidad global no definida por API.
- Motivos: validación local antes de encolar; espacios no cuentan; errores visibles sin
  cerrar el formulario. Observaciones y cuenta respetan longitudes del contrato.
- Evidencia: se muestra el original con zoom antes de confirmar su relación; imagen
  ilegible/no descargable no habilita confirmación. Tras captura se permite revisar o
  volver sin confirmar. Una foto nueva no se relaciona automáticamente.
  “Archivo verificado” significa integridad de archivo, no verificación de su contenido.
- Checklist: cada respuesta es individual; no existe botón de completar todo el bloque.
  Piezas muestran motivos pendientes y enlaces al grupo correspondiente.
- Borradores: actualización atómica de campos de piezas/instalación, guardado con fecha
  local y protección del actor. Se conservan al cambiar de pestaña o cancelar un diálogo.
  Guardado local se diferencia de confirmación del servidor y muestra operaciones pendientes.
- Búsqueda: filtros activos visibles, botón para limpiarlos, mensaje de límite del caché offline.
- Almacenamiento: error de espacio con explicación en español; datos anteriores conservados.

## Validación

- Móvil: 218 pruebas aprobadas y una HTTP opt-in omitida en la suite general;
  recorrido HTTP completo ejecutado aparte: 1 aprobado contra SQL/storage TEST.
- API: 515 unitarias aprobadas; lint, type-check y build correctos.
- Nuevas regresiones: doble envío, campos simultáneos, motivo inválido sin mutación,
  cambio de modelo conservando piezas/fotos, ceros y series repetidas, vigencia GPS,
  bloqueo de botón y diálogo 360×640 con texto 1.8× y teclado.
- Prueba HTTP adicional: A4-A → A1 conservó 9 piezas compatibles y 6 fotos.
  Reenvío idempotente y conflicto concurrente siguieron funcionando.
- Pixel: APK TEST actualizado con `install -r`; filtros activos, contexto del diálogo,
  motivo vacío sin cierre ni operación y acceso directo a pendientes comprobados.
- `flutter analyze` y `git diff --check`: limpios.

## Límites y operación

Las advertencias requieren comprobación humana: no identifican automáticamente una
placa colocada en otro gabinete, ni certifican nitidez, contenido de foto o series por OCR.
No existe un registro global de series únicas en esta implementación. La distancia y
vigencia GPS son protecciones de captura móvil; los permisos, versionado, exclusividad
de base y dictámenes siguen siendo autoridad de la API.

Estas mejoras se instalaron únicamente en `DDR001 Gabinetes TEST` del Pixel, conectada
por USB a la API local. Gabinetes continúa deshabilitado en el entorno de producción.
El ajuste de API para conservar piezas debe acompañar la futura integración del APK.
