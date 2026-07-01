# Catapocket

Catapocket is Catapult's phone-side remote. The Mac app serves a local web remote over Wi-Fi, and this package is the Swift core for the iOS companion path.

## What works now

- Open Catapult Settings > Catapocket.
- Scan the QR code from a phone on the same Wi-Fi network.
- Save links to the Mac, queue links immediately, and watch the Mac queue update.
- Spotify links, playlists, TikTok, YouTube, Instagram, X/Twitter, and other yt-dlp sites go through the existing Catapult download path.
- Offline links can be saved locally and synced back through `POST /api/sync` when the Mac is reachable again.
- The Mac exposes a read-only content library plus stream/download-job endpoints for original and HEVC same-resolution downloads.

## Swift iOS companion core

`CatapultPocketCore` contains portable Catapocket models plus a tiny HTTP client for the Mac server. `CatapultPocketUI` contains the native SwiftUI iPhone/iPad shell.

The native shell now includes:

- iPhone bottom tabs for Pocket, Library, Downloads, and Settings.
- iPad `NavigationSplitView` with sidebar, content, and library detail panes.
- Library downloads for Original, HEVC same-resolution, and Audio.
- Local device downloads with **Save to Photos**, **Export to Files**, and delete.
- Offline link saving and sync through the shared store/client.

Build the shared core from the repo root:

```sh
cd Pocket
swift build
swift build --target CatapultPocketUI
```

## API shape

```swift
let pairing = CatapocketPairingPayload(
    displayName: "Henry's Mac",
    baseURL: "http://192.168.1.23:42173/",
    remoteURL: "http://192.168.1.23:42173/?token=token-from-catapult-settings",
    token: "token-from-catapult-settings",
    serverID: "server-id-from-qr"
)
let pairedClient = try CatapocketClient(pairing: pairing)

let client = CatapocketClient(
    baseURL: URL(string: "http://192.168.1.23:42173")!,
    token: "token-from-catapult-settings"
)

let state = try await client.fetchState()
let response = try await client.queue(CatapocketSubmission(
    url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    mode: .video
))
```

The iOS app should pair by scanning Catapult's Catapocket QR code, then store the base URL, token, and server ID locally. Deprecated `Pocket*` typealiases remain for one release so early clients can migrate cleanly.

## iPhone and iPad app shell

Add both package products to the app target, then make the app entry point tiny:

```swift
import CatapultPocketUI
import SwiftUI

@main
struct CatapocketApp: App {
    var body: some Scene {
        WindowGroup {
            CatapocketRootView()
        }
    }
}
```

The iOS/iPadOS app target must include this Info.plist key because Catapocket can add downloaded videos to Photos:

```xml
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Catapocket saves downloaded videos to your Photos library when you ask it to.</string>
```

Files export uses the system document picker, so the user chooses the Files destination each time.
