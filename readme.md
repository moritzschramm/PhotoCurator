# PhotoCurator

A native macOS app for reviewing camera photos synced through a directory,
curating them into albums, and exporting selected JPGs to a gallery target.
Implements `specification.md` in full (see that file for the authoritative behavior spec).
This README covers how the implementation is organized and how to build/run/test it.
<br>
**DISCLAIMER** this project was fully implemented by Claude Code

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16+ / Swift 5.10 toolchain

## Build & run

**Quick dev loop**
```sh
swift run PhotoCurator
```

**Real sandboxed app**
```sh
Scripts/build_app.sh debug # or: release
open .build/app/PhotoCurator.app
```

**Tests:**
```sh
swift test
```
