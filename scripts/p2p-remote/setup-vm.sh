#!/usr/bin/env bash
# Installs and configures what SwiftCoreWebP2P needs on a public Ubuntu/Debian server so devices on other networks can
# reach a host: coturn (the TURN relay) and Caddy (HTTPS in front of the rendezvous). Run it on the server, as root:
#
#     sudo ./setup-vm.sh                      # public address detected, hostname <ip-with-dashes>.sslip.io
#     sudo ./setup-vm.sh rendezvous.example.com   # your own hostname (an A record to this server)
#
# Safe to run again: an existing shared secret is kept. Nothing is written inside the repository, and the secret is
# printed once, for you to type into the app (it is kept in the Keychain there, never in a file).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"

PUBLIC_IP="$(curl -4 -fsS https://ifconfig.me)"
PRIVATE_IP="$(hostname -I | awk '{print $1}')"
HOSTNAME_FOR_TLS="${1:-${PUBLIC_IP//./-}.sslip.io}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq coturn curl gpg debian-keyring debian-archive-keyring apt-transport-https

# --- coturn ---------------------------------------------------------------------------------------------------------
SECRET=""
if [ -f /etc/turnserver.conf ]; then
  SECRET="$(sed -n 's/^static-auth-secret=//p' /etc/turnserver.conf | head -1)"
fi
[ -n "$SECRET" ] || SECRET="$(openssl rand -hex 32)"

sed -e "s|<SECRET>|$SECRET|" -e "s|<PUBLIC_IP>|$PUBLIC_IP|" -e "s|<PRIVATE_IP>|$PRIVATE_IP|" \
  "$HERE/turnserver.conf.example" > /etc/turnserver.conf
chown root:turnserver /etc/turnserver.conf 2>/dev/null || true
chmod 640 /etc/turnserver.conf
# Debian/Ubuntu ship the service disabled until this line is on.
if [ -f /etc/default/coturn ]; then
  sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
fi
systemctl enable coturn >/dev/null 2>&1 || true
systemctl restart coturn

# --- Caddy (official repository) --------------------------------------------------------------------------------------
if ! command -v caddy >/dev/null 2>&1; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy
fi
sed -e "s|<HOSTNAME>|$HOSTNAME_FOR_TLS|" "$HERE/Caddyfile.example" > /etc/caddy/Caddyfile
systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy

cat <<SUMMARY

Done. Enter these in the app (Showcase: "Remote access settings"):

  TURN host      $PUBLIC_IP
  TURN port      3478
  TURN user      scw
  Shared secret  $SECRET
  Rendezvous     https://$HOSTNAME_FOR_TLS

Still to do:
  - open these TCP ports in the cloud firewall: 80, 443, 3478 and 49160-49200
  - on the Mac that runs the rendezvous, forward its port to this server (see docs/P2P_REMOTE_SETUP.md):
      ssh -N -R 127.0.0.1:9090:127.0.0.1:9090 <user>@$PUBLIC_IP
SUMMARY
