# ShichiZip

The missing 7-Zip derivative intended for macOS.

![screenshot of ShichiZip](https://i.dawnlab.me/2e94b659e94ab1ec187fdb758bc4e7a9.png)

## Build

- Install prerequisites: `brew install xcodegen zig`
- If you use Homebrew Zig on macOS, `zig 0.16.0_1` or newer is required. The `0.16.0` bottle shipped a broken `zig ar`; see [Homebrew/homebrew-core#278849](https://github.com/Homebrew/homebrew-core/issues/278849).
- Generate the Xcode project and derived localization files: `xcodegen generate`

## Variants

- Mainline app: `zig build lib -Doptimize=ReleaseFast -p build && zig build sfx -Doptimize=ReleaseSmall -p build` then `xcodebuild -project ShichiZip.xcodeproj -scheme ShichiZip -configuration Debug -arch arm64 build`
- Zstandard fork variant: `zig build lib -Dvariant=zs -Doptimize=ReleaseFast -p build && zig build sfx -Dvariant=zs -Doptimize=ReleaseSmall -p build` then `xcodebuild -project ShichiZip.xcodeproj -scheme ShichiZipZS -configuration Debug -arch arm64 build`

Use `-Dvariant=all` with `lib`, `sfx`, or `all` to build both variants from the same step. `zig build all` now combines the variant-aware `lib` and `sfx` steps, so `-Dvariant=mainline` builds the mainline pair, `-Dvariant=zs` builds the ZS pair, and `-Dvariant=all` builds both pairs.

Windows SFX builds default to `x86` to match the current app packaging. Use `-Dsfx-arch=x86_64` or `-Dsfx-arch=all` when you need the other architecture(s).
