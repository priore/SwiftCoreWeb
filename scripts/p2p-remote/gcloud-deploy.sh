#!/usr/bin/env bash
# Puts the relay and the HTTPS front of SwiftCoreWebP2P on a Google Cloud server, from your own computer.
# Needs the `gcloud` tool, logged in (`gcloud auth login`), and a project with billing on. Steps and background:
# docs/P2P_REMOTE_SETUP.md
#
#     ./gcloud-deploy.sh up      [--project ID] [--zone ZONE] [--name NAME]   create or start the server and set it up
#     ./gcloud-deploy.sh tunnel  [--project ID] [--zone ZONE] [--name NAME] [--port 9090]   leave running while you test
#     ./gcloud-deploy.sh down    [--project ID] [--zone ZONE] [--name NAME] [--delete]       stop it (or delete it)
#
# `up` prints the values to type into the app, including the shared secret: it is shown once, never written to a file.
# Run `up` again after `down` (a stopped server may come back with another public address; the secret is kept).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NAME=scw-p2p
ZONE=us-central1-a
PORT=9090
DELETE=0
PROJECT_ARGS=()

command -v gcloud >/dev/null 2>&1 || { echo "gcloud is not installed: https://cloud.google.com/sdk/docs/install" >&2; exit 1; }
COMMAND="${1:-}"
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT_ARGS=(--project "$2"); shift 2 ;;
    --zone) ZONE="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --delete) DELETE=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

status() { gcloud compute instances describe "$NAME" --zone "$ZONE" ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"} --format='value(status)' 2>/dev/null || true; }
remote() { gcloud compute ssh "$NAME" --zone "$ZONE" ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"} --quiet --command "$1"; }

case "$COMMAND" in
  up)
    gcloud services enable compute.googleapis.com ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"}
    if ! gcloud compute firewall-rules describe "$NAME" ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"} >/dev/null 2>&1; then
      gcloud compute firewall-rules create "$NAME" ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"} \
        --allow tcp:80,tcp:443,tcp:3478,tcp:49160-49200 --target-tags "$NAME"
    fi
    case "$(status)" in
      "") gcloud compute instances create "$NAME" --zone "$ZONE" ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"} --machine-type e2-micro \
            --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud --boot-disk-size 30GB --tags "$NAME" ;;
      RUNNING) ;;
      *) gcloud compute instances start "$NAME" --zone "$ZONE" ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"} ;;
    esac
    echo "Waiting for the server to accept connections..."
    for _ in $(seq 1 24); do remote true >/dev/null 2>&1 && break; sleep 5; done
    remote 'mkdir -p p2p-remote'
    gcloud compute scp "$HERE/setup-vm.sh" "$HERE/turnserver.conf.example" "$HERE/Caddyfile.example" \
      "$NAME:p2p-remote/" --zone "$ZONE" ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"} --quiet
    remote 'cd p2p-remote && chmod +x setup-vm.sh && sudo ./setup-vm.sh'
    ;;
  tunnel)
    echo "Forwarding port $PORT of this computer to the server. Leave this running; Ctrl-C ends it."
    exec gcloud compute ssh "$NAME" --zone "$ZONE" ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"} --quiet -- \
      -N -R "127.0.0.1:$PORT:127.0.0.1:$PORT" -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes
    ;;
  down)
    if [ "$DELETE" -eq 1 ]; then
      gcloud compute instances delete "$NAME" --zone "$ZONE" ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"}
      gcloud compute firewall-rules delete "$NAME" ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"}
    else
      gcloud compute instances stop "$NAME" --zone "$ZONE" ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"}
    fi
    ;;
  *)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
