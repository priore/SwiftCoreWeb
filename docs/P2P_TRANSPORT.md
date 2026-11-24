# Peer-to-peer access (`SwiftCoreWebP2P`)

[← docs index](README.md)

You are here if: you want a phone, tablet or another Mac to reach the app that is running SwiftCoreWeb **without
opening a port to the network, without a VPN and without a server in between**. The same routes you already wrote
(`mapGet`, `mapPost`, `mapSse`…) answer the other device; only the way in is new. Used both for Web and API.

> **Status.** Pairing, the tunnel, the Bonjour announcement and per-device identity work on the local network; from another
> network a device reaches the host through a TURN relay. Tested on the iOS Simulator and macOS loopback against a real
> `coturn`, not yet on a real device or across real NATs. Direct connections through NAT (hole punching) are not done. See [Limits](#limits).

## How it works

```
 other device                                  host (the app running SwiftCoreWeb)
 ┌───────────┐   SSH over TCP    ┌──────────────────────────────┐
 │ URLSession │ ── loopback ──▶  │ tunnel server                │ ──▶ your routes
 │ any client │   (encrypted,    │ (only paired keys, one       │     (same middleware,
 └───────────┘    authenticated)  │  destination: your app)      │      auth, rate limit)
                                  └──────────────────────────────┘
```

- The tunnel is **SSH** (`swift-nio-ssh`): standard encryption and authentication, no custom protocol.
- A device is trusted because it **paired**: it scanned a one-time code and the host remembered its key. After that it
  connects with the key alone.
- The tunnel forwards to **one destination only**, your app's own HTTP port. It cannot be used as an open proxy.
- Your app does not change: routes, middleware, authentication and `maxConcurrentConnections` apply as before.

## Host: turn it on

```swift
import SwiftCoreWeb
import SwiftCoreWebP2P

let builder = WebApplication.createBuilder()
let p2p = try builder.useP2P()               // nothing runs until you call this
let app = builder.build()
app.mapGet("/api/users") { _ in ["Alice", "Bob"] }   // unchanged
try await app.runAsync()
```

`useP2P(_:name:port:storage:)`:

| Parameter | Meaning |
|-----------|---------|
| `mode` | `.enable` (default) or `.disable`. `.disable` starts nothing and does not touch the Keychain: use it for a setting the user can switch off. It is a switch for the whole feature; which routes devices reach is set separately, see [Choose which routes devices reach](#choose-which-routes-devices-reach). |
| `name` | The name announced on the local network. `nil` uses the device's own name. |
| `port` | The tunnel's port. `0` (default) reuses the last run's port when it is free, so paired devices keep finding the host. |
| `storage` | Where the host key and the paired devices are kept: the Keychain by default (`KeychainTunnelStorage`). Never a file. |

It throws `TunnelError.corruptedStorage` or `.storageUnavailable` when the stored identity cannot be read or written,
instead of silently making a new one (that would invalidate every paired device).

The tunnel starts with the server, stops with it, and starts again after a restart. The host app must declare the
service for the local network announcement in its `Info.plist`:

```xml
<key>NSBonjourServices</key>
<array><string>_scw-p2p._tcp</string></array>
<key>NSLocalNetworkUsageDescription</key>
<string>Lets your other devices reach this app.</string>
```

## Reach the host from another network

On another network (4G/5G, another Wi-Fi) the host is not directly reachable. Two small pieces of infrastructure fix that, and neither can read the traffic, which is SSH between the device and the host:

- a **TURN server** that allows TCP allocations (RFC 6062; `coturn` does, many managed services only relay UDP) and has long-term credentials for the host;
- a **rendezvous**: an SCW app that both can reach, where the host publishes the relay address it got and devices announce themselves.

```swift
// On a public server: any SCW app, behind TLS.
P2PRendezvous().mount(on: rendezvousApp)

// On the host app: the password comes from the Keychain (`SecretStore`), never from a file.
let remote = P2PRemoteAccess(
    rendezvous: URL(string: "https://rendezvous.example.com")!,
    relay: .init(host: "turn.example.com", port: 3478, username: "scw", password: turnPassword)
)
let p2p = try builder.useP2P(remote: remote)
```

Pairing still happens on the local network, and the pairing link then carries the rendezvous address. Later, when the device's `start()` cannot reach the host (remembered address, then Bonjour), it knocks at the rendezvous; the host, which reads its knocks every couple of seconds, lets that device's public address through its relay allocation; the device then connects to the relayed address and speaks SSH to the host as usual. `SCWPeerConnection.currentRoute` says which way it got there (`.local`, `.discovered`, `.relay`). Expect a few seconds of delay on the first connection from outside.

What each party sees: the rendezvous learns the host's key fingerprint, its relay address and the public address and key fingerprint of each device that knocks, all signed by the host or device, so it can withhold or delay but not forge them; a device checks the host's signature against the key it pinned at pairing. The relay moves SSH ciphertext. Only devices that are already paired are let through, and they still authenticate with their key.

## Choose which routes devices reach

By default a paired device reaches every route, like any other client. Narrow that with rules on `WebApplication` or on a route group; the most specific rule wins:

```swift
app.useP2P(.disable)                       // hide everything from paired devices by default...
app.mapGroup("/api").useP2P(.enable)       // ...except the API
app.useP2P("/api/admin", .disable)         // and except one part of it
app.useP2P("/users/{id}/private", .disable) // a {placeholder} segment matches any value
```

A path is matched by whole segments (`/admin` covers `/admin/x`, not `/administrator`), without regard to case, and a path with a `.` or `..` segment is never reachable by a device. A `{placeholder}` segment matches any single segment whatever its constraint (`{id:int}` is not checked), and `{id?}` still needs a segment, so cover an optional parameter's bare path with its own rule. The longest matching rule wins; among rules of the same length the one set last wins, whether it is a literal or a placeholder. A rule on `/` is the same as the default. The percent-decoded form of the path is checked as well.

A route a device may not reach is answered exactly like a path that matches nothing (`404`, the same middleware, headers and metrics, the global body limit), for plain requests and for WebSocket upgrades. Requests that come in on the normal listener (the app's own port) are never affected. The rules are checked at request time, so they can be changed while the server runs. Not covered: requests an extension dispatches itself through `RequestIngress.dispatch`.

## Pair a device

On the host, open a pairing session when the user asks for it (a button, a settings screen) and show the payload as a
QR code (`QRCodeView` in `SwiftCoreWebDashboard` renders any URL):

```swift
let host = LocalAddresses.ipv4().first ?? "127.0.0.1"   // an address the other device can reach
if let payload = p2p.openPairing(host: host, name: "Living room Mac") {
    show(qrFor: payload.link)    // scw-p2p://192.168.1.5:49321?sp=8080&t=…&fp=SHA256%3A…
}
```

On the other device, after scanning:

```swift
let payload = PairingPayload(scannedString)!
let peer = try await SCWPeerConnection.pair(payload)      // once
let base = try await peer.start()                         // http://127.0.0.1:<port>
let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("api/users"))
```

Later launches skip pairing: `try SCWPeerConnection(hostFingerprint:)` then `start()`.

What protects pairing:

- The payload carries the **fingerprint of the host key**. The device refuses any host that presents another key, even
  on a hostile network.
- The token is random (128 bit), **single use**, expires (120 s by default) and allows a few wrong tries.
- A pairing session exists only while the user has opened one. Outside it, only already paired keys can connect.

## Manage devices

```swift
let devices = p2p.pairing?.devices            // [PairedDevice]
p2p.pairing?.rename(deviceID: id, to: "Anna's iPhone")
try p2p.pairing?.revoke(deviceID: id)         // refuses it from now on and closes its open connections
```

`revoke` throws `TunnelError.storageUnavailable` if the removal could not be saved: the device is already refused in
this run, but would be paired again after a restart. Call `revoke` again to retry the save.

## What the app sees

Every paired device is its own client. `HttpRequest.remoteAddress` reads `p2p:<device fingerprint>` instead of
`127.0.0.1`, so logs, metrics and **rate limiting are per device**:

```swift
app.mapGet("/whoami") { ctx in ctx.request.remoteAddress ?? "none" }   // "p2p:SHA256:…"
```

Server-Sent Events work through the tunnel. The rate limiter counts connections: each new connection from the
device uses one token.

## Security notes

- Keys and the device list live only in the Keychain (or the storage you pass). The repository never contains them.
- The loopback address on the other device (`http://127.0.0.1:<port>`) is **not authenticated**: any local process
  that knows the port can use that device's tunnel. Keep the URL inside your app.
- By default the host listens on every IPv4 interface so that other devices can reach it; only paired keys get in.
  Sockets that do not authenticate are closed after 10 s and the tunnel accepts at most 64 connections.
- Anyone on the same network can burn a pairing session's few tries. The session only lasts as long as the user keeps
  it open; open it again if it was closed.
- On iOS the Keychain items are written with the default accessibility (readable while unlocked). A host that must
  start while the device is locked needs a different accessibility class, which `SecretStore` does not set yet.

## Limits

- **Another network goes through a relay.** There is no direct connection through NAT yet: a STUN client exists in the module but nothing uses it, and TCP hole punching is not implemented, so every connection from outside costs the relay's traffic and latency. The relay has to support TCP allocations (RFC 6062); this was verified against `coturn` on the loopback only.
- The TURN credentials are static (one account for the host), not temporary credentials issued per session; the relay address is IPv4 only and is not remembered between runs of the host. The rendezvous keeps its data in memory, so a restart makes hosts republish within a minute; run it behind TLS, and note that behind a reverse proxy it records the proxy's address.
- A device that has never paired cannot connect from outside: pairing needs the host on the local network.
- The client keeps the address it paired with. If `start()` cannot connect to it (no answer; a refusal such as a revoked device is reported as is), the client looks for the host on the local
  network by the fingerprint in its Bonjour announcement (IPv4 only) and remembers the new address. The device's `Info.plist`
  needs the same `NSBonjourServices` and `NSLocalNetworkUsageDescription` entries as the host. The announcement carries the
  host's key fingerprint in clear, so anyone on the network can recognise the host; it grants no access. The announcement is only a hint: the connection still pins the
  host key. Not covered by a test on a real device, and an address that changes while connected is not noticed until the
  next `start()`.
- tvOS is not supported yet.
