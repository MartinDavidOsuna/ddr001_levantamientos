# Photo Integrity

Captura siempre usa `ImageSource.camera`; no existe ruta de galería. JPEG normalizado, thumbnail y SHA-256 se persisten antes de encolar. GPS pertenece a cada foto y exige precisión ≤100 m. La primera foto válida local de paso 1 da canonical provisional; API fija atómicamente la primera verificada.

Estados: localOnly, queued, uploading, uploadedUnverified, verifying, confirmed, retryRequired, permanentFailure, mappingConflict, missingLocal, deleted. Missing original/hash/not found reusan UUID/bytes si existen. Missing thumbnail/mapping espera verify/API repair. Conflictos no se adivinan; deleted no revive. Originales confirmados se retienen en Build 1.
