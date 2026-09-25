# Docs maintenance — keeping `docs/` stable and homogeneous

`docs/` is organized in two parallel branches — `docs/web/` and `docs/api/` — plus a shared
foundation layer (`docs/GETTING_STARTED.md`, `docs/ROUTING_AND_MIDDLEWARE.md`,
`docs/SECRETS_AND_CERTIFICATES.md`, `docs/TESTING_GUIDE.md`, `docs/FAQ_AND_TROUBLESHOOTING.md`) and
a general-reference layer (`docs/DOTNET_MAPPING.md`, `docs/GLOSSARY.md`). Both branches follow the
same internal shape: Getting Started → Basic Examples → Advanced Examples → Auth & Security →
Reference. `docs/README.md` is the index; it must always match the files that actually exist.

**Before adding or extending a feature that touches Web or API surface** (a new route kind,
middleware, auth mechanism, example category):

1. Check whether it belongs in an existing `docs/` file first — never leave it undocumented or
   only mentioned in the top-level `README.md`.
2. If it needs a new file, place it by context, not by convenience:
   - Touches pages/UI/SwiftUI/Vue rendering → `docs/web/`.
   - Touches endpoints/data/JSON contracts → `docs/api/`.
   - Used by both branches (e.g. auth, TLS, testing) → the shared foundation layer, never
     duplicated into both branches.
3. Match the internal shape of the sibling files already in that branch (same section order/
   headings as the other branch's equivalent file). If a feature introduces a category neither
   branch has yet, decide whether it belongs in both (stay symmetric) or is genuinely branch-
   specific — don't add it to only one branch by default.
4. Update `docs/README.md`'s index in the same commit that adds, moves, or renames a doc file.
5. If an existing file is growing too large for one concern (the same symptom that originally split
   the on-device dashboard and .NET mapping table out of the root `README.md`), split it along the
   same Foundation/Web/API axis already established — not an ad-hoc split.
6. If the change is synced to GitHub Wiki (`.github/workflows/wiki-sync.yml` on push to `master`),
   no extra step is needed — the workflow picks up any `docs/**` change automatically.
