#!/bin/sh
# SwiftCoreWeb — self-check for the contributor hooks (throwaway repos, no deps).
# Run: sh scripts/git-hooks/test.sh
set -eu
H="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
export HOME="$T/home"; mkdir -p "$HOME"          # no private-patterns => generic only
export GIT_CONFIG_GLOBAL=/dev/null
cd "$T"; git init -q r; cd r
git config user.name t; git config user.email t@example.org
git config core.hooksPath "$H"
echo ok > a.txt; git add a.txt

# private repo (origin = non-github): nothing is blocked, even with personal data
git remote add origin http://localhost:3000/x/y.git
printf '/Users/someone/x\n' > b.txt; git add b.txt # hooks:allow
git commit -qm private || fail "private repo commit must pass"

# fork (origin = github): generic pattern blocks, marker allows, force mode works
git remote set-url origin https://github.com/x/y.git
printf '/Users/someone/y\n' > c.txt; git add c.txt # hooks:allow
if git commit -qm blocked 2>/dev/null; then fail "fork commit with /Users/ must be blocked"; fi
printf '/Users/someone/y # hooks:allow\n' > c.txt; git add c.txt # hooks:allow
git commit -qm allowed || fail "hooks:allow must pass"
git remote set-url origin http://localhost:3000/x/y.git
SWIFTCOREWEB_HOOKS_MODE=force git commit -q --allow-empty -m e || fail "empty commit must pass"
printf 'a@gmail.com\n' > d.txt; git add d.txt # hooks:allow
if SWIFTCOREWEB_HOOKS_MODE=force git commit -qm blocked 2>/dev/null; then fail "force mode must block gmail"; fi

# pre-push: github URL blocks a range holding the b.txt commit; other URL passes
git reset -q --hard HEAD; git rm -q --cached d.txt 2>/dev/null || true
SHA="$(git rev-parse HEAD)"; Z=0000000000000000000000000000000000000000
printf 'refs/heads/main %s refs/heads/main %s\n' "$SHA" "$Z" | "$H/pre-push" origin http://localhost:3000/x/y.git \
    || fail "non-github push must pass"
if printf 'refs/heads/main %s refs/heads/main %s\n' "$SHA" "$Z" | "$H/pre-push" origin https://github.com/x/y.git 2>/dev/null; then
    fail "github push with personal data in history must be blocked"
fi
echo "git-hooks: all checks passed"
