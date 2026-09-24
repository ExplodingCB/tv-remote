# TV Remote

Native SwiftUI macOS app that recreates the first-generation Siri Remote and controls an
Apple TV over the Companion protocol. Shipped as an ad-hoc signed, universal app through the
`tv-remote` cask in ExplodingCB/homebrew-tap.

## Build & run

```sh
swift build && .build/debug/TVRemote   # dev run (uses Resources/atv_bridge.py from the tree)
./build.sh                              # universal release bundle in build/TV Remote.app
scripts/release.sh 1.0.1 "notes"        # tag, GitHub release, cask bump
```

SwiftPM only, no Xcode project. Swift 5 language mode, macOS 15 deployment target.

Debug builds can render their own window to a PNG (no screen-recording permission needed):
`TVREMOTE_DEMO=1 TVREMOTE_SNAPSHOT=/tmp/out.png .build/debug/TVRemote` shows the connected
layout without a TV; add `TVREMOTE_DEMO_PAIRING=1` for the pairing screen.

## Architecture

- `RemoteModel` owns all state: setup, discovery, connection, pairing, input.
- `Bridge` runs `atv_bridge.py` (pyatv) and speaks line-delimited JSON. Calls with an `id`
  get a reply; `post` is fire-and-forget for high-rate touch events. Input commands are
  queued in order on the Python side.
- `PythonEnvironment` creates the venv in Application Support on first launch (uv preferred,
  then any Python 3.10+).
- `Discovery` browses `_companion-link._tcp` with NetServiceBrowser and passes IPs to pyatv.
- `Touchpad` is an NSView: mouse drag and two-finger scroll become touch events; trackpad
  mode uses raw `NSTouch` positions with the cursor frozen (`CGAssociateMouseAndMouseCursorPosition`).
- `MenuBarController` owns the status item and switches the activation policy between
  `.regular` (window open) and `.accessory` (menu bar only).

## Gotchas learned the hard way

- pyatv's own multicast scan finds nothing on some networks, while mDNSResponder sees every
  device. Always discover in Swift and pass `hosts` to `pyatv.scan`.
- HomePods also report tvOS and advertise Companion. Filter on `raw_model` starting with
  `AppleTV`.
- Only the Companion service is enabled when connecting, so no AirPlay credentials are needed.
- `strokeBorder` on a Capsule leaves a hairline past its ends; use a clipped `stroke`.
- `onGeometryChange` on the safe-area inset feeds back into window sizing; measure it once.
- Never use SF Symbols in the app icon (license). `scripts/make-icon.swift` draws the white
  remote silhouette by hand, matching the look of the `appletvremote.gen4.fill` glyph.
