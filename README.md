# release-tools

One release command for every Flutter app: bump `pubspec.yaml`, build the IPA and AAB, commit, tag, upload to TestFlight and Play.

## Install

```
curl -fsSL https://raw.githubusercontent.com/lumicrafte/flutter_app_release_tool/main/install.sh | bash
```

Run the same line again to update. It installs to `~/.release-tools` and links `release` into `~/.local/bin`.

## Set up once

1. **Signing (Android).** Keep a `keystore.properties` anywhere you like:
   ```
   KEY_ALIAS=...
   KEY_PATH=/absolute/path/to/upload-key.jks
   KEY_STORE_PASSWORD=...
   KEY_PASSWORD=...
   ```
   Then tell the tool where it is, once per machine (`release` also asks the first time it needs it):
   ```
   release signing /path/to/keystore.properties
   ```
   The path is remembered in `~/.config/release-tools/config`. One key serves every app, so keep a backup outside this machine.
2. **Uploads.** Fill in `~/.release-tools/fastlane/.env`: an App Store Connect API key and a Play service account JSON.

## Per app

Nothing to configure: the app name comes from `pubspec.yaml` and the Android package from `applicationId`. An optional `release.config` in the app root can override `APP_NAME`, `ANDROID_PACKAGE` or `KEYSTORE_PROPERTIES`; the `KEYSTORE_PROPERTIES` environment variable overrides all of them.

Make the app's `android/app/build.gradle.kts` read the shared signing file:

```kotlin
val keystoreProperties = Properties()
val keystorePropertiesPath: String? = System.getenv("KEYSTORE_PROPERTIES")?.takeIf { it.isNotBlank() }
    ?: File("${System.getProperty("user.home")}/.config/release-tools/config")
        .takeIf { it.exists() }
        ?.readLines()
        ?.firstOrNull { it.startsWith("KEYSTORE_PROPERTIES=") }
        ?.substringAfter("=")
        ?.trim()
val keystorePropertiesFile = File(keystorePropertiesPath ?: "missing-keystore.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
fun signingValue(key: String): String =
    keystoreProperties.getProperty(key)?.takeIf { it.isNotBlank() }
        ?: throw GradleException("$key is missing in $keystorePropertiesFile")

// in signingConfigs { create("release") { ... } }
keyAlias = signingValue("KEY_ALIAS")
keyPassword = signingValue("KEY_PASSWORD")
storeFile = File(signingValue("KEY_PATH"))
storePassword = signingValue("KEY_STORE_PASSWORD")
```

The first Android release of each app must be uploaded by hand in Play Console.

## Use

```
release                      # asks each question in turn
release patch --upload       # or pass everything as flags
release build --android --dry-run
```

Bump types: `patch`, `minor`, `major`, `build` (build number only), and `current` (no bump: build another platform of the version in `pubspec.yaml`, for example `release current --ios` after an Android-only release; it changes and commits nothing).

The version bump is committed as `release: <app> <version>`; pass `--no-commit` to leave it uncommitted. Tagging is optional: `--tag` also tags the commit as `<app>/v<version>` (the app is the last part of the Android package, so several apps in one repo never collide). Other flags: `--ios`, `--android`, `--upload`, `--dry-run`, `--allow-dirty`.
