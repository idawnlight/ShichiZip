# ShichiZip

The missing 7-Zip derivative intended for macOS.

![screenshot of ShichiZip](https://i.dawnlab.me/2e94b659e94ab1ec187fdb758bc4e7a9.png)

## Build

- Install prerequisites: `brew install xcodegen zig`
  - If you use Homebrew Zig on macOS, `zig 0.16.0_1` or newer is required. The `0.16.0` bottle shipped a broken `zig ar`; see [Homebrew/homebrew-core#278849](https://github.com/Homebrew/homebrew-core/issues/278849).
- Generate the Xcode project and derived localization files: `xcodegen generate`

### Variants

- Mainline app: `zig build lib -Doptimize=ReleaseFast -p build && zig build sfx -Doptimize=ReleaseSmall -p build` then `xcodebuild -project ShichiZip.xcodeproj -scheme ShichiZip -configuration Debug -arch arm64 build`
- Zstandard fork variant: `zig build lib -Dvariant=zs -Doptimize=ReleaseFast -p build && zig build sfx -Dvariant=zs -Doptimize=ReleaseSmall -p build` then `xcodebuild -project ShichiZip.xcodeproj -scheme ShichiZipZS -configuration Debug -arch arm64 build`

Use `-Dtarget=aarch64-native` or `-Dtarget=x86_64-native` to build `lib` for a specific architecture. To do `xcodebuild` for `x86_64` builds, specify `-arch x86_64`.

Use `-Dvariant=all` with `lib`, `sfx`, or `all` (`lib` + `sfx` basically) to build both variants from the same step. But please note `zig build all` won't allow you to choose different optimization levels for `lib` / `sfx`, and the resulting SFX builds will be larger.

Windows SFX builds default to `x86` to match the current app packaging. Use `-Dsfx-arch=x86_64` or `-Dsfx-arch=all` when you need the other architecture(s).

## Contributions

### Localization

The project currently keeps localization in three places:

- `project/localization/Lang` holds the original 7-Zip language files we import from upstream. Treat those files as upstream input; do not edit them for ShichiZip wording. `Upstream.strings` is generated from them, and the generated files are ignored by Git. Use `xcodegen generate`, or run `python3 project/scripts/generate_strings.py` when you only need to refresh that output.
- `App.strings` is the manual app layer. It contains ShichiZip-specific text and overrides for upstream text that needs different wording here. After changing these files, run `python3 project/scripts/format_app_strings.py` to keep the keys sorted and grouped.
- Quick Action text lives under `project/localization/quick-actions` and is expanded into generated `InfoPlist.strings` files during `xcodegen generate`.

When working on a single locale, you can pass just that file to the formatter, for example:

```sh
python3 project/scripts/format_app_strings.py ShichiZip/Resources/Localization/zh-Hans.lproj/App.strings
```
