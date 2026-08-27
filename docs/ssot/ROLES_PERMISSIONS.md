# Roles and Permissions

La autoridad de rol es `GET /construction/profile`; móvil nunca envía role. Contractor sólo ve lo propio, crea evidencia secuencial y no edita etapas cerradas ni identifier/account. Resident ve universo autorizado, revisa metadatos/estado, edita identifier/account/canonical, acepta/rechaza/entrega y no edita fotos/comentarios. Ownership siempre deriva del JWT server, nunca de userId cliente.
