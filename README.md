# release-tools

One release script for every Flutter app: bump `pubspec.yaml`, build the IPA and AAB, commit, tag, upload.

## Per app

Add `release.config` at the app root:

```
APP_NAME=slivet
ANDROID_PACKAGE=com.lumicrafte.slivet
```

Run `~/Desktop/ltl/release-tools/release.sh` from anywhere inside the app (no arguments asks questions; or pass `patch|minor|major|build` plus flags, see the header of `release.sh`).

## One-time setup

- Android signing: one key for all apps in `~/Desktop/ltl/keystore.properties` (`KEY_ALIAS`, `KEY_PATH`, `PASSWORD`, `KEY_PASSWORD`). Each app's `android/app/build.gradle.kts` reads it.
- Uploads: copy `fastlane/.env.example` to `fastlane/.env` and fill in the App Store Connect API key and the Play service account JSON.
- The first Android release of each app must be uploaded by hand in Play Console.
