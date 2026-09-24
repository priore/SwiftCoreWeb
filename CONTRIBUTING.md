# Contributing

Thanks for your interest in contributing. This document applies to any form of contribution: a Pull Request from a fork, a patch sent outside GitHub (email, chat), direct push access, or non-code contributions (documentation, translations, screenshots, graphic assets).

## Contribution license

By contributing, you accept the terms of the [CLA](CLA.md): your contribution is released under the project's license ([PolyForm Noncommercial 1.0.0](LICENSE)) and you grant the author (Danilo Priore) a license to use/relicense it, including for any future commercial agreements.

For Pull Requests, CLA signing is handled automatically by **CLA Assistant**: on your first contribution, the bot asks for a signature in a PR comment. Once signed, it doesn't need to be signed again for later PRs. Merging stays blocked until the CLA is signed.

## How to contribute via Pull Request

1. Fork the repository.
2. Create a descriptive branch (`fix/bug-name`, `feat/feature-name`).
3. Open the Pull Request against `master`.
4. Sign the CLA when the bot asks.
5. Make sure `swift build` and `swift test` pass locally before opening the PR.
6. Wait for the author's review (required, see `CODEOWNERS`).

## Style conventions

Before modifying Swift code, read the conventions in `.claude/swift-style.md` (naming, concurrency, macros, API design) — they keep the library consistent.

## Other contribution channels

- **Patches outside GitHub** (email, chat): the same CLA license applies; the author confirms acceptance before integrating it.
- **Direct push access** (collaborators): same CLA terms, agreed before access is granted.
- **Non-code contributions** (documentation, translations, screenshots, icons/graphic assets): same CLA, same release license.

## Special cases

- **Employees / work for hire**: by submitting, you confirm you have the right to do so, not bound by an employer who claims copyright over it.
- **Minors**: requires a parent's/legal guardian's consent before submission.
- **Anonymous/pseudonymous contributor**: accepted, the GitHub account is enough for traceability.
- **AI-generated/assisted contribution**: the CLA always applies to whoever opens the PR, never to the tool — you remain responsible for the content.
- **Forks that don't contribute back**: don't require a CLA, but remain bound by the license of the code taken (see [LICENSE](LICENSE)).

## Reporting bugs or proposing features

Open an issue using the appropriate template. For security vulnerabilities, don't open a public issue: follow [SECURITY.md](SECURITY.md).

## Code of conduct

By participating in this project you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
