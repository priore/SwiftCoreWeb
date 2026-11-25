# SwiftCoreWeb Showcase

Free for noncommercial use under the [PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0); commercial use requires a separate commercialization agreement with the author. Source-available, not open-source. See `LICENSE` at the repository root.

One iOS app with a menu: every entry starts a real server and shows what it serves. Open `ShowcaseApp/ShowcaseApp.xcodeproj` and press Run (iOS 16+, simulator or device).

```sh
cd Showcase/ShowcaseApp
xcodegen generate        # only after editing project.yml (brew install xcodegen)
open ShowcaseApp.xcodeproj
```

## The menu

| Entry | What it runs | Source |
|-------|--------------|--------|
| Hello World | Static Vue page (built-in Vue runtime, no build step) and one JSON route, listening on the LAN (`http://<device-ip>:8080/`) | `HelloServer.swift`, `www/hello/` |
| Todo API | `@Controller` with `Service<T>` injection, closure routes and groups, JWT + `X-Api-Key` schemes, `@ApiModel` + `/openapi.json`, security headers | `TodoServer.swift`, `TodoController.swift`, `TodoModels.swift`, `www/todos/` |
| Live Pages | Server-driven page: state in Swift, template in `Views/counter.html` | `LivePagesServer.swift`, `Views/` |
| Realtime | Server-Sent Events and a WebSocket echo | `RealtimeServer.swift`, `www/realtime/` |
| Device dashboard | The on-device metrics dashboard for a running server | `DashboardDemoView.swift` |
| P2P host | `useP2P`, `P2PPairingView` (QR code, short code, paired devices), routes reachable through the tunnel (`/whoami`, `/api/users`) | `P2PHostView.swift` |
| P2P client | Pairs from a `scw-p2p://` link and calls the host through the tunnel; shows the route used (`local`, `discovered`, `direct`, `relay`), timings and errors | `P2PClientView.swift` |
| Rendezvous server | `P2PRendezvous` on port 9090, running beside the host | `RendezvousView.swift` |
| Remote access settings | Rendezvous URL and TURN server for the host; the shared secret goes to the Keychain (`SecretStore`) | `SettingsView.swift`, `RemoteSettings.swift` |

Shared plumbing: `ServerRunner` (`AppModel.swift`) stops the previous server before the next one binds port 8080; `ServerGate.swift` starts a server with the screen, stops it when the screen goes away or the app is backgrounded and starts it again when active; `WebHostView.swift` is the `WKWebView` (with the `SwiftCoreWebKit` blob-download helper). Launch with `-demo todos` (any entry's raw name: `hello`, `todos`, `livePages`, `realtime`, `dashboard`, `p2pHost`, `p2pClient`, `rendezvous`, `settings`) to open that screen directly.

## Running on a real device

The project builds for the simulator without any setup. For a device, create `ShowcaseApp/Local.xcconfig` (git-ignored, never commit it):

```
DEVELOPMENT_TEAM = <your team id>
PRODUCT_BUNDLE_IDENTIFIER = com.example.yourname.showcase
```

The app's `Info.plist` already carries what the framework needs: `NSAppTransportSecurity/NSAllowsLocalNetworking`, `NSLocalNetworkUsageDescription`, `NSBonjourServices` (`_scw-p2p._tcp`) and the `scw-p2p` URL scheme, so the Camera app can open a pairing QR code in the showcase.

## Running on the Mac

The target supports Mac Catalyst, so the same app runs as a native Mac process (no simulator): select the *My Mac (Mac Catalyst)* destination, or

```sh
xcodebuild -project ShowcaseApp.xcodeproj -scheme ShowcaseApp -destination 'platform=macOS,variant=Mac Catalyst' -allowProvisioningUpdates build
```

It needs the signing team from `Local.xcconfig` (the sandbox's network-server entitlement and the Keychain access group, both declared in `project.yml`, require a signed app). Use it as the P2P host with an iPhone as the client.

## Trying peer-to-peer

**On the same network.** Run the app on the Mac (iOS Simulator) and open *P2P host*. On an iPhone on the same Wi-Fi, scan the QR code with the Camera app: it opens the showcase on *P2P client* with the link filled in. Tap *Pair*, then *Connect* and *Call /whoami and /api/users*. The log shows the route (`local`) and the time each call took.

**From another network (4G/5G).** Needs a relay (coturn, TCP allocations) and a rendezvous both devices can reach from the internet. A router port-forward does not work behind CGNAT (an address in `100.64.0.0/10` on the router's WAN side). Follow [Peer-to-peer from another network: set-up guide](../docs/P2P_REMOTE_SETUP.md): a free Google Cloud server and `scripts/p2p-remote/setup-vm.sh`, then enter the printed values in *Remote access settings* and run the *Rendezvous server* screen with *Behind a proxy or SSH tunnel* on. Then pair on the local network first and, with the iPhone's Wi-Fi off and the cable unplugged, tap *Connect* in *P2P client*: `relay (TURN)` is the route to expect (`direct` means nothing when the relay shares the host's NAT).

If pairing on the local network fails with `no route to host`, the QR code holds an address the phone cannot reach (a Mac with Ethernet and Wi-Fi has two): pick the other one in the *Address in the QR code* selector, and check *Settings > Privacy > Local Network* on the phone.

## Frontend development workflows (spec the frontend development workflows)

### Mode A — Vue on the Mac, API on the device (recommended)

Full HMR, zero framework code on the frontend side.

1. On the device, call `builder.listenOnAllInterfaces()` (and optionally `builder.advertise(name: "my-iphone")`) instead of the loopback-only default.
2. Copy `Showcase/vite.config.js` into your Vue project's root, and set `DEVICE_HOSTNAME` to your device's Bonjour name or LAN IP.
3. `npm run dev` — Vite opens on the Mac; every `/api/*`, `/openapi.json`, and `/ws/*` request proxies to the device.

### Mode B — Vue running on the device (DEBUG only)

Add `app.useDevDeploy(root: .documents("www"))` under `#if DEBUG` next to `useSpa(root: .documents("www"))` in your server (the showcase screens serve from the app bundle and do not enable it). On launch, the Xcode console prints a random deploy token. To push a build:

```sh
npm run build          # writes dist/
node ../scripts/deploy-to-device.mjs --host my-iphone.local --token <token-from-console>
```

The device writes the upload atomically to `Documents/www` and signals every connected `/__dev/livereload` client to reload. This entire code path does not exist in release builds — `useDevDeploy` is defined only inside `#if DEBUG`.

### Mode C — production

1. Build your Vue project: `npm run build` (writes `dist/`).
2. Add `scripts/copy-dist-to-bundle.sh` as a Run Script build phase on your app target, after "Copy Bundle Resources" (see the comment header in that script for the exact Xcode wiring, including Input/Output Files).
3. The showcase servers already use this shape: `app.useSpa(root: .bundle("www/todos"))`; point it at `.bundle("dist")` for your build.

## Auth quick reference

- **JWT**: `Authorization: Bearer <token>` signed with the HS256 secret written to the Keychain via `SecretStore.write(...)` in `TodoServer.swift`. Issue a demo token with any JWT tool using that secret and `alg: HS256`.
- **API key**: `X-Api-Key: showcase-demo-key` — resolves a principal with the `admin` role, satisfying both `auth: .authenticated` and `auth: .roles(["admin"])` routes (e.g. `DELETE /api/todos/{id}`).

Both schemes are registered in one `.useAuthentication(.jwt(...), .custom("apiKey") { ... })` call; whichever one resolves a principal first wins, and `ctx.user?.scheme` (or `AuthRequirement.scheme("apiKey")` on a route) can require one specifically.
