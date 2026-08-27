# Sync Model

El scheduler causal ejecuta create → open → comment → upload → verify → complete
y complete N antes de open N+1. Los items sobreviven reinicios y un survey fallido
no bloquea otros surveys ready. Retry usa backoff exponencial con jitter.

Finalizar offline valida conteo, archivo, SHA y GPS, marca `completedLocal` inmutable y desbloquea el siguiente paso. `EVIDENCE_NOT_SYNCED` es retryable. La UI distingue Pendiente, Sincronizando, Sincronizado, Sin conexión y Requiere revisión.

En paso 6, `photoPurpose` forma parte de la metadata inmutable del upload y se conserva en reintentos/reuploads con el mismo UUID. Upload 200/201 no cambia la autoridad de verify-batch.

Todos los IDs de queue se reconstruyen desde UUID lowercase. Durante migración
sólo se deduplican jobs con la misma operación, survey, photo/step/correction;
operaciones distintas se preservan. Respuestas verify y list se comparan con
identidad UUID case-insensitive, evitando duplicados de foto, card o marker.

## Location Evidence Model

La adquisición de ubicación es independiente de connectivity y del retry de red.
Upload sólo se encola después de `locationConfirmed`. En modo avión GNSS puede
confirmar la foto y el job media espera Internet. Pending/provisional se persiste,
se recupera al reabrir sólo dentro de la ventana justificable y expira a unresolved.
No existe fallback de “usar ubicación actual” fuera de ventana.
