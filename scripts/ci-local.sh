#!/bin/sh
# Runs .github/workflows/ci.yml's build-and-test steps locally.
# Parses the workflow's own `run:` lines — single source of truth, no drift.
#
# One adjustment: the simulator destination's explicit `OS=` (pinned to
# whatever's on the GitHub runner image) is replaced with whatever OS this
# machine actually has installed for that device name.
#
# ponytail: no YAML lib, `run:` lines in the build-and-test job are always
# single plain scalars on one line — grep+sed is enough. Add a real parser
# if that job ever needs a multi-line `run: |` block. Other jobs (e.g.
# docs-links, ubuntu-only) are out of scope for this local runner.

set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WORKFLOW=".github/workflows/ci.yml"
[ -f "$WORKFLOW" ] || { echo "missing $WORKFLOW" >&2; exit 1; }

# Extract only the build-and-test job's block (stops at the next top-level-2-space job key).
JOB_BLOCK="$(awk '/^  build-and-test:/{f=1} f && /^  [a-zA-Z_-]+:/ && !/^  build-and-test:/{exit} f' "$WORKFLOW")"

echo "==> Steps from $WORKFLOW (build-and-test):"
echo "$JOB_BLOCK" | grep -E '^[[:space:]]*run:' | sed -E 's/^[[:space:]]*run:[[:space:]]*//'
echo

echo "$JOB_BLOCK" | grep -E '^[[:space:]]*run:' | sed -E 's/^[[:space:]]*run:[[:space:]]*//' > /tmp/ci-local-steps.$$
trap 'rm -f /tmp/ci-local-steps.$$' EXIT

while IFS= read -r cmd; do
    case "$cmd" in
        *xcode-select*)
            app="$(echo "$cmd" | grep -oE '/Applications/Xcode[^ ]*\.app')"
            if [ -d "$app" ]; then
                echo "==> $cmd"
                eval "$cmd"
            else
                echo "FATAL: CI requires $app, not installed here (only $(ls /Applications | grep -i '^Xcode' | tr '\n' ' '))." >&2
                echo "A pass with a different Xcode is not a CI pass — install $app (xcodes install, or Apple Developer downloads) before trusting this script." >&2
                exit 1
            fi
            ;;
        *"platform=iOS Simulator,name="*)
            device="$(echo "$cmd" | sed -nE "s/.*name=([A-Za-z0-9 ]+).*/\1/p")"
            [ -n "$device" ] || device="iPhone 16"
            os="$(xcrun simctl list devices available 2>/dev/null | awk -v d="$device" '
                /^-- iOS/ { match($0, /[0-9]+\.[0-9]+/); ver = substr($0, RSTART, RLENGTH) }
                index($0, d" (") { print ver; exit }
            ')"
            [ -n "$os" ] || { echo "no installed simulator for '$device' — install one in Xcode, or edit ci.yml's device name" >&2; exit 1; }
            fixed_cmd="$(echo "$cmd" | sed -E "s/name=[A-Za-z0-9 ]+(,OS=[^']*)?'/name=$device,OS=$os'/")"
            echo "==> $fixed_cmd"
            eval "$fixed_cmd"
            ;;
        *)
            echo "==> $cmd"
            eval "$cmd"
            ;;
    esac
    echo
done < /tmp/ci-local-steps.$$

echo "==> ci-local: all steps passed"
