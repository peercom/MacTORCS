# Build and distribution

Requires macOS 14+, Swift 6 and full Xcode with Metal support. Validated environment:
Apple Silicon, Swift 6.3.3, Xcode 26.6 (17F113). No Homebrew libraries required.
Python 3 is needed only by provenance-check scripts, not the app or Swift tests.

```
swift build
swift test
Scripts/build-app.sh
open build/TORCSMac.app
```

`build-app.sh` creates a regular Retina-aware `.app` with SPM shader resources,
license and notices. Default signing is local ad-hoc signing. Developer ID:

```
TORCS_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/build-app.sh
```

The Developer ID branch enables hardened runtime and a secure timestamp.
For an already-configured notarytool keychain profile, explicit submission is:

```
TORCS_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/notarize.sh PROFILE
```

No signing identity or notary credentials are stored in the repository.
Notarization, Developer ID distribution and clean-machine Gatekeeper acceptance
have not been executed. Local ad-hoc success is not distribution readiness.
Mac App Store is not a release requirement. Sandboxing/content bookmarks remain
future work. Corresponding source and required notices must accompany any
published GPL binary. Do not publish this incomplete lab as a finished game.

Open Package.swift in Xcode and select TORCSMac to build/run there. Packaging is
a documented script rather than a generated Xcode project. The app compiles
its Metal library once at renderer initialization; move to a prebuilt metallib
before active race loading/performance validation. Never compile shaders per tick.
