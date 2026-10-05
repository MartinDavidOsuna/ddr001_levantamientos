# Matriz de operaciones móviles

Prefijo `/api/v1/construction/cabinets`; contrato API `46b0265`.
Todas las mutaciones pasan `operationId`, `expectedVersion`, `capturedAt`;
`Idempotency-Key` coincide con operationId. Actor exclusivamente desde JWT.

| Acción | Operación local | Dependencia de sync | Endpoint / comando | Respuesta esperada | Conflicto / recuperación |
| --- | --- | --- | --- | --- | --- |
| Primer acceso | Caché de catálogo y autorización por usuario | Field residente habilitado | GET `/catalog` | 8 variantes, policy y 84 preguntas | 401/403 oculta caché; 404/incompatible bloquea escrituras |
| Listado/búsqueda | Caché de páginas + detalles; filtro local UID/base/cuenta/modelo | Conexión para completar universo | GET `?page&limit`, GET `/{id}` | items, total, cabinet.version | Mantiene documentos y borradores si falla una página |
| Escanear | UUID local distinto del UID canónico | Catálogo y permiso previamente descargados | GET `/resolve?uid`, POST `/{id}/commands` type `register` | cabinet draft, version 1 | UID_CONFLICT: consultar remoto, conservar/archivar original explícitamente |
| Cerrar registro | Evidencia confirmada local | register → upload → verify | `registration_close` | registered | CAUSAL_PHOTO_MISSING: reparar dependencia; no borrar captura |
| Piezas | Instancias y series por código del catálogo, fotos compartidas | registro cerrado, fotos verificadas | `parts_save`, `parts_validate` | incomplete o validated + pending | Series ilegibles/no disponibles siguen pendientes; revisión explícita |
| Cambiar variante | Nuevo intento con motivo; conserva fotos e historial | Registro cerrado, versión conocida | `identity_correct` | nuevas partDefinitions, invalidación | Revisión de piezas/checklist; reserva de base se conserva |
| Seleccionar base | Base/cuenta propuesta y decisión expresa | Todas las páginas autorizadas de bases | GET `/api/v1/construction/resident/base-surveys?page&pageSize&search` | items + total; accepted/delivered | Offline usa descargadas; BASE_CONFLICT lo decide API |
| Guardar montaje | GPS propio, fecha, respuestas/puntos de evidencia y motivo | piezas validadas + base + fotos verificadas | `installation_save` | documento completo, reserva exclusiva | BASE_STATE_INVALID / ACCOUNT_RESOLUTION_REQUIRED: corregir y nuevo intento explícito |
| Completar instalación | Cierre local distinto de ACK remoto | guardado previo y política sin bloqueantes | `installation_close` | installed, installationOperationId, pending | INSTALLATION_BLOCKED conserva documentos/fotos y motivos |
| Dictamen | Declaraciones, foto posterior, motivo y resolución previa | instalación vigente, foto verificada | `final_review` | deliverable o installed con reviewCorrection | Sin aprobación local ficticia; pendientes bloquean approve |
| Consultar historia | Caché de todas las páginas de snapshots | Conexión para versiones nuevas | GET `/{id}/history?page&limit` | command, result/cabinet, actor y tiempos | Offline conserva snapshots descargados y journal local |
| Fotografías | Archivo único + relaciones por subject | register previo | POST `/{id}/photos`, POST `/{id}/photos/verify`, GET `/{id}/photos`, GET content | storageVerified, metadata/hashes, JPEG/WebP | UUID/bytes estables; reparar mismo archivo; conflicto nunca sustituye bytes |
| Recuperar respuesta | Body durable marcado sending | Mismo actor y UUID | GET `/{id}/operations/{operationId}` | ACK exacto / replayed | 404 reenvía mismo body; VERSION_CONFLICT requiere comparación/nuevo intento |

Los pendientes y aprobación se leen del documento `cabinet.pending/approval`
incluido en respuestas; no se inventa otro cálculo servidor. Los snapshots de
history contienen las versiones consultables, sin necesidad de volver a capturar
84 respuestas. Entregable no incorpora endpoint de entrega.
