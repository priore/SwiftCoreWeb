# Secrets and certificates

[← docs index](README.md)

You are here if: you're wiring up JWT authentication or HTTPS and need to know where the actual
key/certificate material comes from and how to generate it. Used by both the Web and API tracks —
see [web/AUTH_AND_SECURITY.md](web/AUTH_AND_SECURITY.md) and
[api/AUTH_AND_SECURITY.md](api/AUTH_AND_SECURITY.md) for how these plug into routes.

## The rule: secrets never go in a tracked file

SwiftCoreWeb reads secrets from exactly one place: the iOS/macOS Keychain, via `SecretStore`.
Never `appsettings.json`, never `appsettings.Development.json`, never hardcoded in a committed
Swift file (the Showcase app's demo values are the sole exception, and it says so in a comment
right above them — copy the *pattern*, not the literal string).

```swift
// Write once, e.g. during onboarding/first launch:
SecretStore.write("a-long-random-secret", forKey: "jwtSigningSecret")

// Read it back wherever you configure auth:
let secret = SecretStore.read("jwtSigningSecret")
```

`SecretStore.write`/`.read` use `Security.framework`'s generic-password Keychain item under your
app's bundle identifier by default — no third-party crypto or storage dependency.

## Generating a JWT signing secret (HS256)

The simplest case: `AnyAuthenticationScheme.jwt(validate:)` accepts `JwtOptions(hmacSecret:)` for
HMAC-SHA256 tokens. Generate a strong random secret once and store it:

```bash
# 32 random bytes, base64-encoded — plenty for HS256
openssl rand -base64 32
```

```swift
SecretStore.write("<output of the command above>", forKey: "jwtSigningSecret")

builder.services // ... wherever you build your app
app.useAuthentication(
    .jwt(validate: JwtOptions(hmacSecret: SecretStore.read("jwtSigningSecret")))
)
```

If you're validating tokens issued by another system (a separate auth server using RS256/ES256),
use `JwtOptions(publicKeyPEM:)` instead — store the PEM-encoded public key the same way, via
`SecretStore.write`. `hmacSecret` and `publicKeyPEM` are mutually exclusive; pick one.

## Generating TLS certificates for `.useHttps(...)`

`builder.useHttps(p12:passwordKeychainKey:)` needs a `.p12` (PKCS#12) file — a bundle containing
both the private key and certificate — plus its password read from the Keychain via
`SecretStore`. Two paths, depending on what you need:

### Self-signed (local development / device-to-device on a trusted LAN)

Good enough when you control every client that will connect (your own devices, testing), since
clients must explicitly trust the certificate.

```bash
# 1. Generate a private key + self-signed certificate, valid 825 days
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
  -days 825 -nodes -subj "/CN=my-device.local"

# 2. Package into a .p12, setting an export password (you'll store this in the Keychain)
openssl pkcs12 -export -out server.p12 -inkey key.pem -in cert.pem \
  -passout pass:"<a strong password>"

# 3. Clean up the intermediate PEM files — only server.p12 is needed
rm key.pem cert.pem
```

Then in your app:

```swift
// Ship server.p12 as a bundle resource, or copy it to Documents at first launch.
SecretStore.write("<the password from step 2>", forKey: "tlsP12Password")

builder.useHttps(p12: .bundle("server.p12"), passwordKeychainKey: "tlsP12Password")
```

Clients connecting to a self-signed certificate will see a trust warning unless they've explicitly
trusted it (e.g. installed the `.pem` as a trusted root profile on the connecting device). That's
expected — self-signed is for development and closed/trusted-LAN deployments, not public-facing
servers.

### CA-issued (a certificate a normal browser/client trusts without warnings)

1. Generate a private key and a Certificate Signing Request (CSR):

   ```bash
   openssl req -new -newkey rsa:2048 -nodes -keyout key.pem -out request.csr \
     -subj "/CN=your-real-domain.example.com"
   ```

2. Submit `request.csr` to your Certificate Authority (Let's Encrypt, your org's internal CA, a
   commercial CA) — the exact submission process depends on the CA. You get back a signed
   certificate (`cert.pem`) and possibly an intermediate chain (`chain.pem`).

3. Package the signed certificate (plus chain, if provided) with your private key into a `.p12`:

   ```bash
   openssl pkcs12 -export -out server.p12 -inkey key.pem \
     -in cert.pem -certfile chain.pem -passout pass:"<a strong password>"
   ```

4. Same wiring as the self-signed case: ship `server.p12`, store the password with `SecretStore`,
   call `builder.useHttps(p12:passwordKeychainKey:)`.

A CA-issued certificate needs a real, resolvable domain name (`CN=your-real-domain.example.com`) —
it doesn't work for a bare LAN IP or a `.local` Bonjour name, since the CA has to verify you control
that domain. For a device serving only its own LAN, self-signed is the realistic option; CA-issued
matters when the server is reachable from the public internet under a real domain.

## Where the `.p12` file itself lives

The `.p12` file is not a secret by itself (its password is) but treat its distribution carefully:
ship it as a bundle resource only for development/internal builds, or generate/download it at
first run into `Documents` for a production flow where each device gets a distinct certificate.
Either way, add any local `.p12`/`.pem`/`.key`/`.csr` file you generate while developing to
`.gitignore` immediately — see
[`.claude/rules/sensitive-data.md`](../.claude/rules/sensitive-data.md) for the full checklist and
the `git ls-files` verification command to run before every push.
