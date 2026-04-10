# ShichiZip

The missing 7-Zip derivative intended for macOS.

![screenshot of ShichiZip](https://i.dawnlab.me/2e94b659e94ab1ec187fdb758bc4e7a9.png)

## Variants

- Mainline app: `make lib-mainline` then `xcodebuild -project ShichiZip.xcodeproj -scheme ShichiZip -configuration Debug -arch arm64 build`
- Zstandard fork variant: `make lib-zs` then `xcodebuild -project ShichiZip.xcodeproj -scheme ShichiZipZS -configuration Debug -arch arm64 build`
