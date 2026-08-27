# Sync Model

Orden persistente: profile → survey → open step → upload → verify → comment → complete. Los items sobreviven reinicios. Retry usa backoff exponencial (exponente máximo 8) y jitter; la cola detiene el ciclo al fallar una dependencia.

Finalizar offline valida conteo, archivo, SHA y GPS, marca `completedLocal` inmutable y desbloquea el siguiente paso. `EVIDENCE_NOT_SYNCED` es retryable. La UI distingue Pendiente, Sincronizando, Sincronizado, Sin conexión y Requiere revisión.

En paso 6, `photoPurpose` forma parte de la metadata inmutable del upload y se conserva en reintentos/reuploads con el mismo UUID. Upload 200/201 no cambia la autoridad de verify-batch.
