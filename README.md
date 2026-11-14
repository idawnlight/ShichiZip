# ShichiZip

The missing 7-Zip derivative intended for macOS.

![screenshot of ShichiZip](https://i.dawnlab.me/2712265ec4056f5aa89d68a1688ac184.png)

## Features

- (Most) 7-Zip File Manager experience, rebuilt natively for macOS.
- Full 7-Zip format support. Everything supported by upstream 7-Zip.
- One-click smart extraction that auto-picks the best destination and strips duplicate top-level folders.
- Preview archives in Finder and files inside archives with Quick Look, without extracting.
- Additional macOS-specific features, including stripping resource forks and best-effort integration with Finder.

## Install

Release builds are available on the [Releases](https://github.com/idawnlight/ShichiZip/releases) page. Both arm64 and x86_64 builds for the mainline and Zstandard fork variants are provided.

This app is also available on [Homebrew Cask](https://formulae.brew.sh/cask/shichizip) and [MacPorts](https://ports.macports.org/port/shichizip/details/), but please note MacPorts version is built from source separately and not the same binary provided in releases. You may pick either package manager you prefer:

```sh
# Homebrew Cask
brew install --cask shichizip # Mainline Variant
brew install --cask shichizip-zs # Zstandard Fork Variant

# MacPorts
sudo port install shichizip # Mainline Variant
sudo port install shichizip +zstd # Zstandard Fork Variant
```

If you want to install the nightly builds or get more rapid updates via Homebrew Cask, you may use [a separate Homebrew Tap](https://github.com/shichizip/homebrew-tap); see the README of that repository for details.

```sh
brew tap shichizip/tap
brew install --cask shichizip # / shichizip-zs / shichizip@nightly / shichizip-zs@nightly
```

## Build

See [BUILD.md](BUILD.md) for prerequisites, build steps for both variants, and an overview of the project layout. The [CI workflow](.github/workflows/build.yml) is the canonical reference if anything in the docs falls behind.

## Contributing

All types of contributions are welcome.

This project is also happy to accept contributions from LLM, with only one requirement: it should be reviewed carefully by a human being before submission, and you must clearly know what you are doing.

### Localization

The project currently keeps localization in three places:

- `project/localization/Lang` holds the original 7-Zip language files we import from upstream. Treat those files as upstream input; do not edit them for ShichiZip wording. `Upstream.strings` is generated from them, and the generated files are ignored by Git. Use `xcodegen generate`, or run `python3 project/scripts/generate_strings.py` when you only need to refresh that output.
- `App.strings` is the manual app layer. It contains ShichiZip-specific text and overrides for upstream text that needs different wording here. After changing these files, run `python3 project/scripts/format_app_strings.py` to keep the keys sorted and grouped.
- Quick Action and Finder service menu text lives under `project/localization/quick-actions` and is expanded into generated `InfoPlist.strings` and `ServicesMenu.strings` files during `xcodegen generate`. Finder service labels inside Settings belong to `App.strings`, so they follow the app's selected language.

When working on a single locale, you can pass just that file to the formatter, for example:

```sh
python3 project/scripts/format_app_strings.py ShichiZip/Resources/Localization/zh-Hans.lproj/App.strings
```

## License

ShichiZip is licensed under [LGPL-2.1](LICENSE), only to avoid any potential licensing conflicts with the upstream code.

See submodules in `vendor/` for the licenses of the upstream 7-Zip code.
