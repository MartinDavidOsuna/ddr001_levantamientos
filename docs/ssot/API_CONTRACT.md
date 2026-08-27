# API Contract

Fuente: API SHA `90ee7e770f3a66105220c05a60e3b5ed48c7da1d`.

- Field auth: `POST /field-sessions/start`, `POST /field-sessions/refresh`, `POST /field-sessions/:id/end`.
- Profile: `GET /construction/profile`.
- Contractor: create/list/detail/map; open/patch/complete steps; multipart step/correction photos; corrections.
- Integrity: `POST /construction/photos/verify-batch`, máximo 100 IDs.
- Resident: list/map, patch identifier/account, reject/accept/deliver, canonical correction.

UUIDs móviles e Idempotency-Key hacen reintentables creación/finalización. Un upload 201 nunca es confirmación final.
