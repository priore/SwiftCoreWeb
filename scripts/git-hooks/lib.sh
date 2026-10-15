#!/bin/sh
# SwiftCoreWeb — shared helpers for the optional contributor git hooks.
# Opt-in: `scripts/git-hooks/install.sh`. POSIX sh, no dependencies.
#
# Content checks are active only when `origin` points at github.com (a
# contributor's fork) or SWIFTCOREWEB_HOOKS_MODE=force. SWIFTCOREWEB_HOOKS_MODE=off
# disables them. False positives: add `# hooks:allow` on the line, or a regex
# per line (matched against the file path) in a `.hooksignore` file.
# Optional extra patterns: ~/.config/swiftcoreweb/private-patterns
# (ERE per line, `identity: Name <email>` lines = identities allowed on commits).

HOOKS_GENERIC='/Users/[^/[:space:]]+/|C:\\Users\\[^\\[:space:]]+\\|(^|[^0-9.])(10\.[0-9]+|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]+\.[0-9]+|[A-Za-z0-9._%+-]+@(gmail|outlook|hotmail|yahoo|icloud)\.[A-Za-z]+|-----BEGIN [A-Z ]*PRIVATE KEY-----' # hooks:allow
HOOKS_PRIVATE="${SWIFTCOREWEB_PRIVATE_PATTERNS:-$HOME/.config/swiftcoreweb/private-patterns}"

# Active for commit-time hooks: origin on github.com, or forced.
hooks_active() {
    case "${SWIFTCOREWEB_HOOKS_MODE:-}" in
        force) return 0 ;;
        off) return 1 ;;
    esac
    case "$(git config --get remote.origin.url 2>/dev/null || true)" in
        *github.com*) return 0 ;;
        *) return 1 ;;
    esac
}

# Writes the pattern file (generic + private) to the path in $1.
hooks_patterns() {
    printf '%s\n' "$HOOKS_GENERIC" > "$1"
    if [ -r "$HOOKS_PRIVATE" ]; then
        grep -vE '^[[:space:]]*(#|identity:|$)' "$HOOKS_PRIVATE" >> "$1" || true
    fi
}

# Scans the added lines of `git diff <args>`; prints `file:line` per hit
# (never the matched text) and returns 1 if any.
hooks_scan_diff() {
    _pf="$(mktemp)"
    hooks_patterns "$_pf"
    _ign="$(git rev-parse --show-toplevel)/.hooksignore"
    [ -r "$_ign" ] || _ign=/dev/null
    _hits="$(git diff "$@" -U0 --no-color --no-ext-diff \
        | awk -v ignf="$_ign" '
            BEGIN { while ((getline l < ignf) > 0) if (l != "" && l !~ /^#/) ign[++ni] = l }
            /^\+\+\+ b\// { f = substr($0, 7); skip = 0
                for (i = 1; i <= ni; i++) if (f ~ ign[i]) skip = 1; next }
            /^@@/ { match($0, /\+[0-9]+/); n = substr($0, RSTART + 1, RLENGTH - 1) - 1; next }
            /^\+/ && !/^\+\+\+/ { n++; if (!skip && $0 !~ /hooks:allow/) print f ":" n ":" substr($0, 2) }' \
        | grep -E -f "$_pf" | cut -d: -f1,2 || true)"
    rm -f "$_pf"
    [ -z "$_hits" ] && return 0
    printf '%s\n' "$_hits" >&2
    return 1
}

# Prints commit identities in the rev args (e.g. a range) that are not allowed.
# No private-patterns file (a plain contributor) => nothing to compare, passes.
hooks_bad_identities() {
    [ -r "$HOOKS_PRIVATE" ] || return 0
    _idf="$(mktemp)"
    grep -E '^identity:' "$HOOKS_PRIVATE" | sed -E 's/^identity:[[:space:]]*//' > "$_idf"
    if [ -s "$_idf" ]; then
        git log "$@" --format='%an <%ae>%n%cn <%ce>' | sort -u | grep -vxF -f "$_idf" || true
    fi
    rm -f "$_idf"
}
