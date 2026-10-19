# Sensitive data and `.gitignore` — mandatory check

This repository is public on GitHub. No sensitive data (credentials, signing keys, local paths, machine-specific config) must ever end up in a commit.

**Before adding any new file, folder, or persistence mechanism** (a new example app writing local config, a new cache/log file, a new integration requiring credentials) — explicitly assess whether it contains or could contain sensitive data, and if so:

1. Add the path to `.gitignore` **in the same commit** that introduces it, not later.
2. Secrets (JWT signing keys, `.p12` passwords, API keys) never go in `appsettings.json`/`appsettings.Development.json` or any tracked file — they belong in the Keychain via `SecretStore`, per the library's own design (see README "Configuration & environment"). If a Showcase/example app needs a placeholder secret to run, use an obvious non-secret placeholder, never a real value.
3. Before every push to the public remote (or any time something might have slipped through), verify no sensitive path was ever tracked:
   ```
   git ls-files | grep -E "\.p12$|\.key$|\.pem$|appsettings\.Production\.json$"
   git log --all --full-history -- <suspect path>
   ```
   Both must return empty. If something shows up tracked, it must be removed from history (`git filter-repo` or equivalent) before pushing — removing it only from the working tree is not enough, it stays in past commits.

Don't treat `.gitignore` as a one-time static guarantee: re-check it every time a new data source or example app is introduced, not just once at project start.

## Private vs public repository

Principle: the private/internal repository may contain everything; the public repository must never
contain personal identifiers (real names, personal emails, absolute home paths, machine-specific
details). Never rewrite the internal history to achieve this.

- Fix problems at the source on the development branch (no absolute paths, neutral examples,
  no references to non-public documents in published files).
- Anything personal that must stay in the internal repo lives under an internal-only path
  (`.claude/memory-private/`, `.claude/settings.local.json`, planning docs) that the publish
  pipeline strips.
- Personal strings and allowed identities are kept **outside the repository**, in the maintainer's
  private configuration directory read by the publish script at run time — never in tracked files,
  commit messages or reports.
- Automatic controls: the publish script rewrites identities/contents on a throwaway clone and
  aborts if anything personal remains; the `pre-push` hook refuses a direct push to a public
  remote; contributors can opt in to `scripts/git-hooks/`, and CI runs the generic scan on PRs.
