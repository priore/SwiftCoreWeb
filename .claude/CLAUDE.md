# SwiftCoreWeb — project rules

Server-side Swift 6 HTTP library (swift-tools 6.0, swift-nio), platforms iOS 15 / macOS 11.
The repository is public on GitHub: no credentials, personal data or machine-specific paths in tracked files.

## Language
Files under `.claude/` are written in English (chat replies are Italian, per global rules).

## Build & test
- Plain `swift build` / `swift test` do not work here: `swift` on PATH is an old swiftly toolchain and
  `SwiftCoreWebDashboard` imports UIKit. Use `xcodebuild` with an iOS Simulator destination.
- Full CI parity before any push: `scripts/ci-local.sh` (skill `ci-local`).
  Single target and macro tests (the macros bundle runs on the host, not the simulator): skill `test-target`.

## Read before acting
- Editing `*.swift` → `.claude/swift-style.md`.
- Adding any file, folder or persistence mechanism → `.claude/rules/sensitive-data.md` (the repo is public).
- Adding or extending a feature with Web/API surface → `.claude/rules/docs-maintenance.md` (also auto-loads on `docs/**`).
- Writing project memory → `.claude/memory-rules.md`. Index: `.claude/memory/MEMORY.md` — read it when the task
  touches CI, build/test, changelog, docs or publishing; verify referenced files still exist before relying on a note.
- Dependabot PRs → agent `dependabot-triage` (CI already auto-merges patch/minor bumps; the weekly major-review
  workflow needs an `ANTHROPIC_API_KEY` repo secret, otherwise it is a no-op).

## Concreteness
Never state hypotheses about this library's behavior: verify against the source (grep/read) first.
Wrong claims about the API are costly for the people building servers on it.
