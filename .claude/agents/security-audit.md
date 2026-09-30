---
name: security-audit
description: Audit sicurezza su auth middleware, session handling, CORS
context: fork
user-invocable: false
---

# Security Audit Subagent

Esamina authentication middleware + session handling per vulnerabilità comuni.

## Scope

Analizza:
- `Sources/SwiftCoreWeb/AuthenticationMiddleware.swift` — token verification, expiry checks
- `Sources/SwiftCoreWeb/Session.swift` — session lifecycle, fixation risks
- `Sources/SwiftCoreWeb/CorsMiddleware.swift` — origin validation, header bypass
- Qualunque route che tocca JWT o credenziali
- Qualunque middleware di autenticazione custom

## Checks

1. **Token Expiry**
   - Usa `<=` non `<` per confronti time boundary
   - Expiry non è mai ignorato
   - Clock skew è gestito (se applicabile)

2. **CORS Bypass**
   - Origin validation non è bypassabile con origin header manipulation
   - Credentials flag è corretto
   - Preflight non bypassa auth

3. **Session Fixation**
   - Nuova sessione dopo login
   - Old session token non riusa dopo upgrade auth
   - Logout invalida token

4. **Timing Attacks**
   - JWT verification non dipende da lunghezza/content
   - Constant-time comparison usato dove necessario

5. **HTTPS Enforcement**
   - Secure flag su cookies
   - HSTS header presente (se applicable)

6. **Input Validation**
   - Bearer token format validato
   - JWT claims validati prima di uso

## Output

Report con:
- ✅ Aree sicure
- ⚠️ Rischi low/medium
- 🔴 Vulnerabilità confirmed con scenario exploit
- 💡 Fix consigliate

## Trigger

Automatico: prima di merge su master (via hook commit).
Manuale: invocazione diretta in caso di change auth-related.

Esempio:
```
claude -p "@claude audit all auth code for timing attacks and session fixation"
```
