---
name: openapi-export
description: Esporta schema OpenAPI dal TestHost e aggiorna docs/api/REFERENCE.md
disable-model-invocation: false
user-invocable: true
---

# openapi-export Skill

Genera documentazione OpenAPI a partire dalle rotte registrate nel Showcase e aggiorna docs/api/.

## Invocazione

```bash
/openapi-export
```

## Cosa fa

1. Introspeziona rotte + parametri + schemi dal TestHost del Showcase
2. Esporta schema OpenAPI 3.0 JSON
3. Aggiorna `docs/api/REFERENCE.md` con endpoints, metodi, path/query params, request/response bodies

## Prerequisiti

- Showcase/App deve compilare (contiene rotte di esempio)
- Routes devono essere registrate nel builder del Showcase
- TestHost deve esporre introspection API

## Output

- `docs/api/REFERENCE.md` aggiornato con spec OpenAPI
- Schema JSON nella forma `docs/api/_openapi.json` (opzionale, per tool esterni)

## Note

Usa solo routes che sono già nel Showcase (rotte di test, non implementazioni private).
Non aggiunge rotte che non esistono.
