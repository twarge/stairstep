# Stairstep

Stairstep is a document-based SwiftUI viewer for 3D model files.

The macOS app opens STEP (`.step`, `.stp`, `.p21`), IGES (`.iges`, `.igs`), OpenCascade BREP (`.brep`, `.rle`), STL, PLY, OBJ, and binary glTF (`.glb`) documents, tessellates or imports them with the OpenCascade importer carried over from the sister `horizontal` app, and renders the result in SceneKit. The shared SwiftUI shell and SceneKit scene builder are written for macOS, iOS, and iPadOS.
The macOS bundle also embeds Finder Quick Look preview and thumbnail extensions for supported 3D model documents.
File > Open Demo Model on macOS, or the Open Demo Model action on the iOS and iPadOS document launch screen, opens a bundled stair sample STEP model.

A cross-section tool clips the model against an axis-aligned plane (X, Y, or Z) so you can see inside. Turn it on from the toolbar or the View menu, then position the plane with the inspector's slider or millimeter field, or by clicking/tapping a point on the model. The default cut faces the camera; "Flip Side" keeps the opposite half, and "Solid Cap" fills the exposed face so the cut reads as solid rather than hollow.

## Platform Notes

- macOS uses the generated static OpenCascade build in `Vendor/OpenCascadeStatic/macos-arm64` for real model import and tessellation. The source for that build lives in the `Vendor/OCCT` submodule.
- macOS embeds `StairsQuickLookPreview.appex` and `StairsQuickLookThumbnail.appex` under `Contents/PlugIns` so Finder Quick Look can preview supported 3D model files and generate Finder thumbnails with the same importer and SceneKit scene factory as the main app.
- iOS and iPadOS use `Vendor/OpenCascadeStatic/OpenCascadeStairs.xcframework` for the same OpenCascade-backed importer when the generated iPhoneOS and iPhoneSimulator slices are present.
- The generated iPhoneSimulator slice is arm64-only, so the Xcode iOS targets exclude x86_64 simulator builds.
- macOS carries Horizontal's custom trackpad pan and magnify behavior. iOS and iPadOS use custom touch gestures for orbit, pinch-to-zoom, and two-finger pan, and also support trackpad two-finger pan and pinch-to-zoom.

## Third-Party Notices

Stairstep uses Open CASCADE Technology (OCCT) 8.0.0 for model import and tessellation.

Open CASCADE Technology is copyright OPEN CASCADE S.A.S. OCCT is licensed under the GNU Lesser General Public License version 2.1 with the Open CASCADE exception. Stairstep links OCCT statically on macOS and iOS, so source distributions and binary releases should include the OCCT license texts and enough source/build materials for users to rebuild Stairstep with a modified compatible OCCT build.

RapidJSON 1.1.0 is vendored in `Vendor/RapidJSON` and used by OCCT's glTF importer. RapidJSON is licensed under the MIT License.

The OCCT license texts used by this project are included by the `Vendor/OCCT` submodule and copied into the generated static install at:

- `Vendor/OpenCascadeStatic/macos-arm64/share/doc/opencascade/LICENSE_LGPL_21.txt`
- `Vendor/OpenCascadeStatic/macos-arm64/share/doc/opencascade/OCCT_LGPL_EXCEPTION.txt`
- `Vendor/OpenCascadeStatic/ios-arm64/share/doc/opencascade/LICENSE_LGPL_21.txt`
- `Vendor/OpenCascadeStatic/ios-arm64/share/doc/opencascade/OCCT_LGPL_EXCEPTION.txt`
- `Vendor/OpenCascadeStatic/ios-simulator-arm64/share/doc/opencascade/LICENSE_LGPL_21.txt`
- `Vendor/OpenCascadeStatic/ios-simulator-arm64/share/doc/opencascade/OCCT_LGPL_EXCEPTION.txt`

The macOS app bundle also copies these texts to `Contents/Resources/ThirdPartyLicenses/OpenCascade`, and the RapidJSON MIT license to `Contents/Resources/ThirdPartyLicenses/RapidJSON`.

OCCT source for this build comes from the Open CASCADE `V8_0_0` tag through the `Vendor/OCCT` git submodule. RapidJSON source comes from the Tencent `v1.1.0` tag through the `Vendor/RapidJSON` git submodule. Generated static archives are intentionally ignored by git.

## Build

`make` builds the macOS app exactly the way pressing Build in Xcode does — same scheme, configuration, and DerivedData, so make and Xcode share one incremental build — first building the vendored OpenCascade static libraries if they are missing. `make run` builds and launches, like Build & Run. `make help` lists the other targets (`release`, `ios`, `spm`, `icon`, the forced `occt*` rebuilds, and cleanup). The dependency targets wrap the scripts below, which remain the source of truth.

Build the Swift package with Swift 6.2 or newer (the app targets and Quick Look extensions need Xcode 26 for the macOS / iOS 26 SDKs):

```sh
swift build
```

Rebuild the macOS OpenCascade static archives:

```sh
git submodule update --init --recursive Vendor/OCCT Vendor/RapidJSON
scripts/build-occt.sh
```

Rebuild the iOS OpenCascade static archives and XCFramework:

```sh
git submodule update --init --recursive Vendor/OCCT Vendor/RapidJSON
scripts/build-occt-ios.sh
scripts/build-occt-xcframework.sh
```

The static OpenCascade builds use OCCT 8.0.0 with dynamic third-party dependencies disabled and RapidJSON enabled for binary glTF import. OCCT is LGPL 2.1 with an exception; static linking can have licensing implications, so review `Vendor/OCCT`, `Vendor/RapidJSON`, and `Vendor/OpenCascadeStatic/*/share/doc/opencascade` before distributing binaries.

Distribution builds are plain Xcode archives: `.github/workflows/appstore.yml` archives and uploads both apps to App Store Connect (see [Releases](#releases)), and the same thing works locally with Product ▸ Archive in Xcode — the Organizer then uploads to App Store Connect or signs and notarizes a Developer ID copy for direct distribution.

You can also open `Stairstep.xcodeproj` in Xcode. It contains native targets for:

- `Stairs`, a unified app target for macOS, iPhone, and iPad builds.
- `StairsQuickLookPreview` and `StairsQuickLookThumbnail`, the macOS Quick Look extensions.

The Swift package remains available for command-line builds and for keeping the package manifest in sync with the source layout.

## Releases

`.github/workflows/appstore.yml` archives the iPadOS and macOS apps and uploads them to App Store Connect (TestFlight / review) on `v*` tags, or manually from the Actions tab. Archive signing uses the Apple Development identity imported from the `BUILD_CERTIFICATE_BASE64`/`P12_PASSWORD` secrets; export signing and provisioning are cloud-managed by xcodebuild through the App Store Connect API key (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` — the key needs the Admin role). The macOS App Store build is sandboxed through the app target's macOS-only entitlements (`App/Stairs.entitlements`). The OpenCascade static libraries are cached on the submodule revisions, so only the first run pays for that build. The macOS app can also ship outside the Mac App Store: archive in Xcode (Product ▸ Archive) and use the Organizer's Direct Distribution flow, which Developer ID signs and notarizes with local credentials.

## License

The Stairstep source code is released under the Apache License, Version 2.0; see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). The bundled and statically linked third-party components keep their own licenses, as described under [Third-Party Notices](#third-party-notices) above.
