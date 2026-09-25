# Project Rules & Coding Standards

## Chat Language

- **Mandatory**: all chat replies (conversational text, explanations, summaries) must be in Italian, always. This does not apply to code/code comments (which stay in English) nor to technical names/APIs.
- **Mandatory, applies to written files too**: any `.md` file under `.claude/` (memory files, `MEMORY.md`, rules, plans, docs) must be written in English — same as code comments. Only chat replies are in Italian.

## Memory

- Before replying, running a tool, or running a terminal command, check **both** memory indexes:
  - Global (cross-project): `/Users/danilo/.claude/memory/MEMORY.md` — user preferences and generalizable lessons, valid across other projects too.
  - Local (this project): `.claude/memory/MEMORY.md` — facts/decisions/feedback specific to SwiftCoreWeb.
- When saving a new memory: if it's generalizable to any project (e.g. user style preferences, debugging methodology), it goes in the global memory; if it depends on files/architecture/decisions of this project, it goes in the local one.
- Verify that the retrieved information is still valid (referenced files/symbols still exist) before using it as the basis for a recommendation or an action.
- Before writing or updating a file in memory, read [.claude/memory-rules.md](./memory-rules.md) — rule on what must NEVER be saved there (step status/history, which lives only in a plan/tracking doc if one exists).
- Local memory is versioned in the repo at `.claude/memory/` — plain files, no symlink needed for a single-machine checkout; if cloned elsewhere, memory travels with the repo automatically.

## Swift

Before writing or modifying any `*.swift` file, read [.claude/swift-style.md](./swift-style.md) (naming, concurrency, macro conventions, API design) — not loaded by default, to reduce tokens on every session.

## Publishing / sensitive data

This repository is public on GitHub. Before adding any new file, folder, or persistence mechanism, read [.claude/rules/sensitive-data.md](./rules/sensitive-data.md) — mandatory check for credentials/secrets never ending up in a commit.

## Docs (`docs/`) maintenance

`docs/` is the human-facing wiki (also synced to GitHub Wiki, see `.github/workflows/wiki-sync.yml`),
distinct from `AI-Workspace/` (AI-facing knowledge base — never cross-link the two as if interchangeable).
Before adding or extending a feature with Web or API surface, read [.claude/rules/docs-maintenance.md](./rules/docs-maintenance.md) — keeps the two-branch (`docs/web/`, `docs/api/`) structure stable and homogeneous.

## Dependabot triage

Use the `dependabot-triage` agent ([.claude/agents/dependabot-triage.md](./agents/dependabot-triage.md)) when asked to check/manage the repo's Dependabot PRs.

CI also runs this automatically: `.github/workflows/dependabot-auto-merge.yml` merges patch/minor bumps with no extra setup, and `.github/workflows/dependabot-major-review.yml` triages major bumps on a weekly cron — but the latter needs an `ANTHROPIC_API_KEY` secret on the GitHub repo to actually run; without it, the job is a no-op (same as it currently is on the sibling Timesheet project).

## Concreteness

Never formulate hypotheses, only concrete ones, mandatory! Verify against the actual source (grep/read) before asserting behavior — this is a library other people build servers on, wrong claims about its API are costly.
