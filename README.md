# Glint

A minimal, ad-free YouTube + YouTube Music client for iPhone, designed for foldable iPhones: a phone layout on the cover screen and a tablet-class layout on the inner screen.

## Features

- **Every resolution**: 144p up to 4K/8K, high frame rate and HDR where YouTube offers them. Pick the exact quality or use Auto (adaptive).
- **No ads**: Glint has its own player and talks to YouTube's InnerTube API directly. Ad renderers, promoted videos and sponsored shelves are dropped while feeds are parsed.
- **SponsorBlock**: auto-skips sponsors, self-promotion, interaction reminders, intros/outros, previews, filler and non-music sections. Segments are drawn on the timeline. Lookups use a partial SHA-256 hash of the video ID.
- **Accounts**: sign in with Google and add as many accounts as you want. Switch from the avatar menu. Shows your Home, Subscriptions, History, Watch later, Liked videos and playlists. Subscribe, like and save to Watch later. Each account has its own session, stored in the Keychain.
- **YouTube Music**: Home, Explore, Charts, search, albums, artists, playlists, Liked songs and endless radio queues. Audio-only mode, plus a Song/Video switch.
- **Player**: Picture in Picture, background audio, lock screen and Control Center controls, AirPlay, playback speed, double-tap to seek, drag down to minimise, a mini player that follows you around the app, and autoplay.
- **iPhone Duo layout** (follows Apple's *Preparing your app for iPhone Duo* guidance)
  - **One system `TabView` (`.sidebarAdaptable`)** for every size.
    - Outer display: a tab bar, or the vertical bars iOS 27.1 shows on a closed Duo.
    - Inner display: a sidebar.
    - The view hierarchy never changes when you fold or unfold, so navigation and playback carry over.
  - **Mini player** in the system tab bar bottom accessory, so iOS places it correctly next to horizontal or vertical bars.
  - **`ArrangementView`** for the watch page and Music Now Playing.
    - Wide display: side by side.
    - Tall display: stacked.
    - Half-open: on either side of the fold.
  - **Immersive player:** an overlay arrangement moves the controls and the video apart at the fold.
  - **Fold-aware feed grid:** reads the fold's reserved region, so cards never straddle the hinge in book posture.
  - **Layout decisions** come from size classes and container geometry, never from device type, orientation or screen size.
  - **Toolbar items** carry an icon and a title, so iOS can place them in vertical bars, horizontal bars or the overflow menu.
  - **Liquid Glass** controls throughout.

## Building

The app builds only on GitHub Actions. The workflow is `.github/workflows/build.yml` and runs on the self-hosted macOS runner labelled **`xcode-27`**:

1. Selects Xcode 27.
2. Installs [XcodeGen](https://github.com/yonaskolb/XcodeGen) and generates `Glint.xcodeproj` from `project.yml`. The project file is generated, not committed.
3. Builds an unsigned Release build for devices.
4. Packages it as **`Glint.ipa`** and uploads it as the `Glint-<version>-build<build>-ipa` artifact. The build log is uploaded too.

A second, opt-in job, `screenshots` (run it from the Actions tab, or put `[screenshots]` in a commit message), builds a Debug simulator app and captures the main screens for design review: iPhone Duo outer display, plus an iPad mini as a stand-in for the regular-width inner display. It uploads them as the `screenshots` artifact. The job is informational and never blocks the `.ipa`.

The workflow runs on every push and pull request. You can also start it by hand from the Actions tab (`workflow_dispatch`).

### Installing

The `.ipa` is unsigned. Sign and install it with your own tool, for example AltStore, SideStore, Sideloadly or `codesign` with your Apple developer certificate. The bundle ID is `com.glint.Glint`; change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` if you need your own.

Requirements: iOS 27 or later (built for iPhone Duo; the fold APIs need iOS 27.1).

### Versioning

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` are the single source of truth. Every change bumps them:
- the marketing version (`1.0.1` → `1.0.2`, or a minor/major bump for bigger releases);
- the build number by 1.

The CI artifact name includes both, so you can always tell builds apart.
- AV1 streams (1440p and above on most videos) are offered only on devices with hardware AV1 decoding (A17 Pro and newer).
- On other devices, Glint offers the highest-quality H.264 stream instead.

## How playback works

YouTube serves high resolutions as separate video and audio streams in fragmented MP4 (DASH), which AVPlayer cannot play directly. Glint does the following:

1. Reads the `sidx` index of each stream with a small range request.
2. Builds HLS playlists on the device: an `EXT-X-MAP` entry plus `EXT-X-BYTERANGE` segments pointing straight into YouTube's files.
3. Serves those playlists to AVPlayer through an `AVAssetResourceLoader` custom scheme.

AVPlayer then streams, buffers, seeks, adapts and runs Picture in Picture natively. Live streams use YouTube's own HLS manifests.

## Project layout

```
Glint/
  App/          App entry, settings
  Core/         Foundation-only: InnerTube client, parsers, stream resolver,
                synthetic HLS, SponsorBlock, auth (SAPISIDHASH), accounts
  Playback/     PlayerController, resource loader, Now Playing, player layer/PiP
  UI/           SwiftUI: Root (adaptive shells), Home, Search, Watch, Music,
                Library, Channel, Settings, shared components
project.yml     XcodeGen spec
```

## Maintenance notes

- YouTube changes its private API from time to time. The client identities are in `Glint/Core/InnerTube/ClientProfile.swift`; usually bumping a version there is the only fix needed.
- Playback tries the `ANDROID_VR` client first because it returns direct stream URLs without proof-of-origin tokens. The `IOS` client is the fallback.
- Google sign-in happens in an isolated web view with a Safari user agent. If Google ever blocks embedded sign-in, sign-in is the only feature affected. Browsing, search, Music and playback all work signed out.
