# Peer-to-peer from another network: set-up guide

[← docs index](README.md) · [← Peer-to-peer access](P2P_TRANSPORT.md)

You are here if: your app uses `SwiftCoreWebP2P` and a device must reach it **from another network** (4G/5G, another
Wi-Fi), not only from the same Wi-Fi. This page takes you from nothing to a working set-up, one step at a time, on a free
Google Cloud server. You do not need to know anything about networking beforehand.

> **Status.** Tested end to end once: a Mac behind a carrier-grade NAT (no port forwarding possible) as host, a free-tier
> `e2-micro` Ubuntu 24.04 server with `coturn` and Caddy, and an iPhone on mobile data with Wi-Fi off. The connection used
> the relay (`peer.currentRoute == .relay`). The direct route (`.direct`) was not seen working in that test. Other carriers
> and networks may behave differently, so read [Troubleshooting](#troubleshooting) and [Diagnosing](#diagnosing-what-reaches-the-server).

## Do I need this?

| What you want | What to set up |
|---------------|----------------|
| Devices on the **same Wi-Fi** reach the app | Nothing. `useP2P()` is enough ([Peer-to-peer access](P2P_TRANSPORT.md)). |
| Devices on **other networks** reach the app | The two pieces on this page: a **relay** and a **rendezvous**. |

Why two pieces? A phone on 5G cannot open a connection to your Mac or iPhone: both sit behind their provider's network
equipment (NAT), which only lets connections out, not in. So both sides connect **out** to a small server on the internet
that has a public address:

- the **relay** (a *TURN server*, here `coturn`) passes the already encrypted bytes between the two devices. It cannot
  read them: the traffic is SSH between the device and your app.
- the **rendezvous** is a tiny web service where the app says "I am reachable through this relay address" and a device
  says "I want to talk to that app". It is part of this library (`P2PRendezvous`).

```
 phone on 5G ──▶ relay (coturn) ◀── your app (Mac or iPhone, behind NAT)
      │                                   ▲
      └──── rendezvous (HTTPS) ───────────┘   "where is the app?" / "someone is knocking"
```

Both pieces are the same for every app that uses the library, so you set them up once.

## What you need

- A Google account and the [`gcloud` command line tool](https://cloud.google.com/sdk/docs/install) (`brew install --cask google-cloud-sdk`, then `gcloud init`). Google asks for a payment card when you open a project; the free tier is
  [described here](https://cloud.google.com/free/docs/compute-getting-started) (one small `e2-micro` machine in certain US regions, check the current list and limits there: they change).
- The Mac (or any Apple machine) that will run the rendezvous. The rendezvous is a SwiftCoreWeb app, so it runs on Apple
  platforms, not on the Linux server. For a test it can be the Mac you develop on.
- About 30 minutes.

Any Debian or Ubuntu server with a public IPv4 address works the same way: open the ports of step 2 in its firewall and run the script of step 3 on it.

## The short way: one script

If you have `gcloud` installed and logged in (`gcloud auth login`) and a project with billing on, [`scripts/p2p-remote/gcloud-deploy.sh`](../scripts/p2p-remote/gcloud-deploy.sh) does steps 1 to 3 for you:

```sh
scripts/p2p-remote/gcloud-deploy.sh up --project <your-project-id>      # creates (or starts) the server and sets it up
scripts/p2p-remote/gcloud-deploy.sh tunnel --project <your-project-id>  # step 4's tunnel; leave it running
scripts/p2p-remote/gcloud-deploy.sh down --project <your-project-id>    # stops the server (add --delete to remove it)
```

`up` ends by printing the values for step 5, the secret included. Run it again after `down`: the secret is kept, and if the
server came back with another public address the values it prints are the new ones. Options: `--zone`, `--name`, and `--port` for `tunnel`.
The rest of this page explains what the script does, one step at a time, for when you want to do it by hand or on another provider.

## Step 1: create the server

```sh
gcloud compute instances create scw-p2p \
  --zone us-central1-a --machine-type e2-micro \
  --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
  --boot-disk-size 30GB --tags scw-p2p
```

(If `gcloud` asks to enable the Compute Engine API, answer yes. If the zone is not in the free tier any more, pick one that is.)

## Step 2: open the ports

The server is closed by default. Open exactly what is needed:

```sh
gcloud compute firewall-rules create scw-p2p \
  --allow tcp:80,tcp:443,tcp:3478,tcp:49160-49200 --target-tags scw-p2p
```

| Port | Used for |
|------|----------|
| 80, 443 | HTTPS for the rendezvous (80 only to obtain the certificate) |
| 3478 | the relay's control connection |
| 49160–49200 | the ports the relay hands out to connections (a small range is enough) |

## Step 3: install the relay and HTTPS on the server

Copy the three files in [`scripts/p2p-remote/`](../scripts/p2p-remote) to the server and run the script:

```sh
gcloud compute scp --recurse scripts/p2p-remote scw-p2p:~ --zone us-central1-a
gcloud compute ssh scw-p2p --zone us-central1-a -- 'cd p2p-remote && sudo ./setup-vm.sh'
```

The script installs `coturn` and `Caddy`, creates a **shared secret** and prints, at the end, everything you need:

```
  TURN host      203.0.113.7
  TURN port      3478
  TURN user      scw
  Shared secret  4f9c…
  Rendezvous     https://203-0-113-7.sslip.io
```

Keep this output: you type these values into your app (step 5). The hostname ending in `sslip.io` is a free name that
points to the address in it, so Caddy can get a real HTTPS certificate without you owning a domain. If you have a domain,
create an `A` record for it and pass it to the script (`sudo ./setup-vm.sh rendezvous.example.com`).

Run the script again at any time: the secret is kept. To make a new one, delete `/etc/turnserver.conf` on the server and run it again.

## Step 4: run the rendezvous

In an app on your Apple machine, mount it on a loopback-only server:

```swift
import SwiftCoreWeb
import SwiftCoreWebP2P

let builder = WebApplication.createBuilder()
builder.usePort(9090)                       // loopback only: the tunnel below is the way in
let app = builder.build()
P2PRendezvous(trustForwardedFor: true).mount(on: app)
try await app.runAsync()
```

(The Showcase app does this in its *Rendezvous server* screen: switch on *Behind a proxy or SSH tunnel* and start it.)

Then connect the server to it with an SSH tunnel, and leave this running:

```sh
gcloud compute ssh scw-p2p --zone us-central1-a -- \
  -N -R 127.0.0.1:9090:127.0.0.1:9090 -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes
```

Caddy receives HTTPS requests from the internet and passes them through this tunnel to your rendezvous. **Why
`trustForwardedFor: true`:** the rendezvous records the address each device connects from, and the relay later lets exactly
that address in. Behind Caddy and the tunnel the connection comes from the server itself, so the rendezvous must read
the real address from the `X-Forwarded-For` header Caddy adds. The option is honoured only for connections that arrive
from the loopback address, so a request that reaches the rendezvous any other way cannot choose the address it is recorded
under. Leave it `false` (the default) when devices connect to the rendezvous directly.

Check it from any computer:

```sh
curl -i https://203-0-113-7.sslip.io/p2p/v1/hosts/test
```

`404` with a small JSON body means it works (nothing is registered under that name). `502` means the tunnel is not running.
A certificate error right after step 3 usually passes after a minute.

If your rendezvous runs on an always-on Apple machine that is directly reachable from the internet, no tunnel and no
`trustForwardedFor` are needed: put it behind HTTPS and use its address in step 5.

## Step 5: tell the app

Store the shared secret once, in the Keychain (never in a file, never in the repository):

```swift
SecretStore.write(secretFromStep3, forKey: "turnSharedSecret")   // once, e.g. from a settings screen
```

and give the host app the addresses:

```swift
let remote = P2PRemoteAccess(
    rendezvous: URL(string: "https://203-0-113-7.sslip.io")!,
    relay: .init(host: "203.0.113.7", port: 3478, username: "scw",
                 sharedSecret: SecretStore.read("turnSharedSecret") ?? "")
)
let p2p = try builder.useP2P(remote: remote)
```

Use the server's **IPv4 address** (or a name that has only an `A` record) for the relay: 5G networks often use IPv6, and the
relay only lets IPv4 through. The Showcase app has the same fields in *Remote access settings*.

## Step 6: try it

1. **Pair on the same Wi-Fi first** (QR code, see [Pair a device](P2P_TRANSPORT.md#pair-a-device)). The pairing link now also carries the rendezvous address.
2. On the phone, turn **Wi-Fi off** and Personal Hotspot off. If it is connected to the Mac with a cable, unplug it: a cable gives the phone a second route that would hide a problem.
3. Start the connection (`peer.start()`). The first connection from outside can take 10–20 seconds.
4. `peer.currentRoute` should be `.relay`. `.direct` (a connection with no relay) only happens through some NATs, and it
   proves nothing when the relay and the host share one network.

## Troubleshooting

| What you see | Most likely cause | What to do |
|--------------|-------------------|------------|
| `curl` to the rendezvous gives `502` | the SSH tunnel is not running | start the `ssh -R` command of step 4 again |
| `curl` gives a certificate error | the certificate is not ready, or ports 80/443 are closed | wait a minute; check the firewall rule of step 2 |
| `TunnelError.directConnectionFailed` | neither the direct attempt nor the relay worked | check ports 3478 and 49160–49200; `nc -vz <server-ip> 3478` from another network must succeed |
| Works on Wi-Fi, not on 5G | the TURN host is a name with an `AAAA` (IPv6) record, or the relay address is not IPv4 | use the IPv4 address of the server |
| The relay refuses the host (authentication) | wrong shared secret, or the clock of the host is wrong | copy the secret again; the credentials carry a time stamp, so set the host's clock automatically |
| Error `-1022` on the phone | the rendezvous URL is `http://`: iOS blocks plain HTTP to the internet | use the HTTPS address |
| The relay log shows `CREATE_PERMISSION ... error 403` and then `peer has no permission to connect` | the rendezvous recorded the wrong address for the device (the tunnel's own, `127.0.0.1`) | start the rendezvous with `trustForwardedFor: true` (in the Showcase: switch on *Behind a proxy or SSH tunnel* **before** pressing *Start*) |
| `badResponse(status: 502)` | the rendezvous is not running, or the `ssh -R` tunnel is down | start both again; restarting the rendezvous needs no new pairing |
| `badResponse(status: 404)` right after the rendezvous was restarted | the rendezvous keeps host records in memory only; the host publishes again every 60 seconds | wait a minute and try again |
| *Address already in use* when starting the rendezvous or the host | it is already running in that window | do nothing: it is already listening |
| The route says Bonjour, though Wi-Fi and Bluetooth are off | the phone is connected to the Mac by a cable, which is a network too | unplug the cable before the test |
| `no route to host` (errno 65) when pairing on the Wi-Fi | the QR code holds an address the phone cannot reach (a Mac with Ethernet and Wi-Fi has two) | pick the other address in the pairing screen; check *Settings > Privacy > Local Network* for your app on the phone |

On the server, `sudo journalctl -u coturn -n 50` and `sudo journalctl -u caddy -n 50` show what each service saw.

## Diagnosing what reaches the server

If a connection from outside fails, find out how far it got. Every command below runs on your own server over `ssh`
(`gcloud compute ssh scw-p2p --zone us-central1-a -- '<command>'`). Remove the extra logging afterwards: it records the
addresses of whoever connects.

**Did the phone reach the rendezvous?** Add `log` inside the site block of `/etc/caddy/Caddyfile`, run `sudo systemctl reload caddy`, then:

```sh
sudo journalctl -u caddy --since "-5min" -o cat | grep "handled request"
```

One JSON line per request (`remote_ip`, `uri`, `status`). The phone's requests end in `/knocks` (`204` = accepted); the host's end in `/knocks/collect`.

**Did the phone reach the relay?** Watch for new connections on the relay's control port and on the relay port range:

```sh
sudo tcpdump -n -i any "(tcp port 3478 or portrange 49160-49200) and tcp[tcpflags] & tcp-syn != 0"
```

**What did the relay decide?** Add `verbose`, `log-file=stdout` and `simple-log` to `/etc/turnserver.conf`, run `sudo systemctl restart coturn`, then:

```sh
sudo journalctl -u coturn --since "-5min" -o cat | grep -vE "usage:"
```

A working connection shows, in order: `ALLOCATE ... success` (the host), `CREATE_PERMISSION ... success` (the host lets the device in),
`tcp accepted from: <the device's address>` and `CONNECTION_BIND ... success`.

Stopping the server and starting it again may give it a new public address; unless you reserved a static one
(`gcloud compute addresses create`), repeat step 3 and update the settings after each start.

## Costs, safety and cleaning up

- Relayed traffic leaves the server and counts as outgoing traffic of the free tier; a test uses very little.
- The relay accepts only connections with credentials derived from the shared secret, and those expire after an hour. Keep the secret in the Keychain and out of the repository, and never post the script's output.
- The rendezvous has no per-client limit of its own: put the app's `rateLimit` in front of it if it is open to the world.
- Stop paying for nothing: `gcloud compute instances stop scw-p2p --zone us-central1-a` when you are done, or delete the server (`instances delete`) and the firewall rule (`firewall-rules delete scw-p2p`).
