#!/bin/bash
# Proves the P2P tunnel is plain SSH: pairs a device in a test, then connects to the host with the machine's own `ssh`
# (OpenSSH) using that device's key, and forwards an HTTP request to the app. Run from the repository root.
set -euo pipefail

DIR="$(mktemp -d)"
TEST_PID=
trap '[ -n "$TEST_PID" ] && kill "$TEST_PID" 2>/dev/null; rm -rf "$DIR"' EXIT
chmod 700 "$DIR"
DEVICE="${SCW_SIM_DEVICE:-iPhone 17}"

# TEST_RUNNER_ variables reach the test process without the prefix.
TEST_RUNNER_SCW_INTEROP_DIR="$DIR" xcodebuild test -skipMacroValidation -scheme SwiftCoreWeb-Package \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -only-testing:SwiftCoreWebP2PTests/OpenSSHInteropTests > "$DIR/xcodebuild.log" 2>&1 &
TEST_PID=$!

for _ in $(seq 1 600); do [ -f "$DIR/ready" ] && break; kill -0 "$TEST_PID" 2>/dev/null || break; sleep 1; done
[ -f "$DIR/ready" ] || { echo "the test did not start the host"; tail -20 "$DIR/xcodebuild.log"; exit 1; }
read -r TUNNEL APP < "$DIR/ready"

SSH_OPTS=(-F /dev/null -i "$DIR/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes -o "UserKnownHostsFile=$DIR/known_hosts"
          -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -p "$TUNNEL")
{
    # stdin stays open a moment: `ssh -W` ends when it reaches EOF, before the answer comes back.
    { printf 'GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'; sleep 3; } | ssh "${SSH_OPTS[@]}" -W "127.0.0.1:$APP" scw@127.0.0.1 2>&1 || true
    echo "--- a destination outside the allow-list (port 22) ---"
    printf '' | ssh "${SSH_OPTS[@]}" -W 127.0.0.1:22 scw@127.0.0.1 2>&1 | head -c 300 || true
} > "$DIR/result.tmp"
mv "$DIR/result.tmp" "$DIR/result.txt"
echo "ssh output:"; sed 's/^/  /' "$DIR/result.txt"

if wait "$TEST_PID"; then echo "OpenSSH interoperability: OK"; else echo "OpenSSH interoperability: FAILED"; tail -30 "$DIR/xcodebuild.log"; exit 1; fi
