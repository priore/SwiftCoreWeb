---
name: test-target
description: Esegui test isolato su un target Swift specifico (core, testing, dashboard)
disable-model-invocation: false
user-invocable: true
---

# test-target Skill

Esegui test su un target specifico senza ricompilare gli altri.

## Invocazione

```bash
/test-target core
/test-target testing
/test-target dashboard
```

## Cosa fa

```bash
swift test -c release --filter <target>Tests
```

Compila solo il target richiesto e relative dipendenze. Utile per feedback loop rapido durante sviluppo.

## Target disponibili

- `core` → SwiftCoreWebTests
- `testing` → SwiftCoreWebTestingTests (se esiste)
- `dashboard` → SwiftCoreWebDashboardTests

## Nota

Se il target non ha test, il comando fallisce silenziosamente (exit 0, nessun test trovato).
