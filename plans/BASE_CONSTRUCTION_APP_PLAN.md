# Base Construction App — Build 1

## PRODUCTION RELEASE RUNBOOK

La promoción queda condicionada a HTTPS confirmado, firma definitiva, E2E TEST/físico, backup verificado y smoke/rollback del runbook API. Esta preparación no autoriza SQL, deploy ni publicación productiva.

Baseline API: `90ee7e770f3a66105220c05a60e3b5ed48c7da1d`; extensión cardinal: `ddade065cb2ca9eb12803e1f6a3ff7bef83eca1c`. Baseline móvil RV inspeccionado: `e6b7438fd48d8b3b38d10bf520ffc8ceb3f5b7b4`. La app Viewer no estuvo disponible localmente.

Implementado: proyecto Flutter nuevo Android/iOS, field auth persistente, bootstrap de rol, survey offline, pasos 1–6 secuenciales, cámara-only, ubicación por foto, canonical de primera foto válida del paso 1, persistencia Hive v1, cola idempotente, upload/verify, listas/merge/search/filter, mapa por rol, perfil, estados rechazados/correcciones y revisión residente. Paso 6 exige Norte, Este, Sur y Oeste y admite adicionales ilimitadas. Instalación de hidrante queda como placeholder.

La certificación real requiere API local TEST, credenciales field TEST y dispositivo Android con cámara/GPS. Ningún test debe usar producción.
