# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| `master` / latest release | ✅ |
| Previous versions | ❌ |

No commitment to release retroactive fixes for versions prior to the current one.

## How to report a vulnerability

**Do not open a public issue** for a security vulnerability.

Preferred channel: [GitHub Security Advisories](https://github.com/priore/SwiftCoreWeb/security/advisories/new) (private until resolved).

Alternatively, contact the author directly via email (see the [@priore](https://github.com/priore) GitHub profile).

Please include, if possible: reproduction steps, affected version/commit, estimated impact.

## Timelines

Indicative response within 7-14 days. Project maintained by a single person: no binding SLA, but reports are taken seriously and prioritized over other work.

## What is covered by this security model

SwiftCoreWeb is a library others use to build HTTP/HTTPS/WebSocket servers inside an iOS app. The security model covers:

- The library itself (`Sources/SwiftCoreWeb`): HTTP parsing, TLS handling, authentication/authorization middleware, rate limiting.
- Secrets handling: JWT signing keys and `.p12` passwords always go through `SecretStore` (Keychain), never in plaintext on disk — a regression that wrote them to disk would be a vulnerability.

## What is not covered by this security model

- The security configuration of servers built **with** the library (authorization policy, CORS, rate limits) is the consumer's responsibility — the library provides the mechanisms, not the application policy.
- Binding to `127.0.0.1` by default (no LAN exposure) is a deliberate choice; if a consumer calls `listenOnAllInterfaces()`, that network exposure is their decision, not a library bug.
- Vulnerabilities in `swift-nio`, `swift-nio-transport-services`, `swift-syntax` should be reported upstream, to their own repositories (`apple/swift-nio`, etc.), not here — still verify whether the project is impacted before closing as "not ours".

## No warranty

The software is provided as-is, without express or implied warranties — see [LICENSE](LICENSE).
