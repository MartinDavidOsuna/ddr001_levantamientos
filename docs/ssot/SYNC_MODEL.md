# Sync Model

Orden persistente: profile → survey → open step → upload → verify → comment → complete. Los items sobreviven reinicios. Retry usa backoff exponencial (exponente máximo 8) y jitter; la cola detiene el ciclo al fallar una dependencia.

Finalizar offline valida conteo, archivo, SHA y GPS, marca `completedLocal` inmutable y desbloquea el siguiente paso. `EVIDENCE_NOT_SYNCED` es retryable. La UI distingue Pendiente, Sincronizando, Sincronizado, Sin conexión y Requiere revisión.
