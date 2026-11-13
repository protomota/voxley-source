# Voxley

Voxley is a native SwiftUI dictation app for Apple Silicon Macs running macOS 26 or later. Apple Speech’s `SpeechAnalyzer` and `SpeechTranscriber` turn audio into text on the Mac. Apple Intelligence’s default on-device Foundation Model optionally cleans up or formats that text. Voxley has no server, account, API key, or third-party model.

[Download and install Voxley](https://voxley.si/download/).

## Open and dictate

1. Open Voxley from Applications. Look for the waveform icon in the menu bar.
2. Click the waveform icon and choose **Voxley Onboarding… → Permissions**. Select **Allow Microphone** and choose **Allow** when macOS asks. If previously denied, open [Microphone privacy settings](x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone) and turn on Voxley.
3. For **Automatic paste**, choose **Open System Settings**. In [the macOS privacy pane](x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility) (called **Device Control and Data Access** on this Mac), turn on Voxley. If Voxley is absent, click **+**, press **⌘⇧G**, enter `/Applications/Voxley.app`, and click **Open**. Return to Voxley and click **Check Permissions Again**.
4. Click a text field in any app. Tap **Control–Shift–Space** to start dictating and tap it again to stop, or hold it and release when you finish speaking. The card sits at the bottom center of the display and shows up to three lines of live text. Voxley pastes into the original field, or copies the text if it can’t paste.
5. To use your own shortcut, open **Voxley Onboarding… → Keyboard shortcut → Record Shortcut…** and press the combination. Use a key with a modifier or a function key. Common editing commands such as **Command–V** are reserved for editing. Press **Escape** to cancel. Press the saved shortcut to check that Voxley detects both press and release.
6. Under **Practice dictation**, click the field and dictate the sample phrase. **Test Paste** checks the practice field separately from the microphone and shortcut. Practice phrases are not saved to history. After dictating in another app, return to this screen to see whether Voxley confirmed the paste or only sent it.

The first dictation for a language may take longer while macOS installs the Apple Speech language asset. If you want text cleanup, check **Apple Intelligence** in Voxley Settings. If it is off, open [Apple Intelligence & Siri settings](x-apple.systempreferences:com.apple.Siri-Settings.extension), enable Apple Intelligence, and wait for its model to become available. Dictation can still return the original transcript when cleanup is unavailable.

## What’s in this build

- A menu bar control and a small floating recorder with a microphone indicator, live waveform, transcript, and Stop button.
- Verbatim, Clean up, Notes, and Email modes, with overrides by app.
- Vocabulary hints and literal word replacements.
- Local text history is available in backup exports. Use **Copy Last Transcript** from the menu bar to retrieve the latest result. Turn history off in Settings to stop saving new entries.
- JSON backup and restore for preferences, dictionary, app modes, and transcript history. Restore applies the backed-up settings and merges transcripts by ID. Backups contain readable transcript text.


## Build and test

Open `Package.swift` in Xcode 27 or later, or run `swift build` and `swift test` from the repo root. The scripts below are Protomota’s packaging workflow and expect a volume mounted at `/Volumes/Expand`.

```sh
./Scripts/build-app.sh
./Scripts/test-app.sh
./Scripts/test-app.sh --with-models
```

Build products and the synthetic test audio go to Expand. To sign the first build with a Developer ID, set `VOXLEY_SIGNING_IDENTITY` to the signing identity in your login keychain. Later builds reuse the Developer ID from the existing app so macOS can recognize the same app across updates. When moving from an ad-hoc build to a Developer ID build, grant Microphone and Automatic Paste to the signed app once.

## Package the direct-download installer

The Developer ID release includes Sparkle. It checks for updates in the background and installs signed updates automatically when possible. Users can turn automatic installation off in **Settings → General → Updates** or select **Check for Updates…** in the menu bar. Sparkle uses its own preferences and does not send dictation data.

```sh
build_tools='/Volumes/Expand/Codex Media/Voxley/Build/dmg-tools'
release_dir='/Volumes/Expand/Codex Media/Voxley/Release/1.0.6'
python3.12 -m venv "$build_tools"
"$build_tools/bin/python" -m pip install -r Packaging/macOS/requirements.txt
VOXLEY_RELEASE=1 VOXLEY_SIGNING_IDENTITY='Developer ID Application: Protomota, LLC (22HV69L32T)' \
  ./Scripts/build-app.sh "$release_dir"
./Scripts/release-dmg.sh "$release_dir" --keychain-profile "$NOTARYTOOL_PROFILE"
```

Use a fresh release directory and a higher `CFBundleVersion` for each update. The packaging script makes the branded drag-to-Applications DMG, verifies its mounted contents, signs and notarizes it, and generates the signed `appcast.xml` after stapling. It uses the `voxley-direct` Sparkle signing identity and verifies that its public key matches the app. The private signing key stays in the macOS Keychain.

To publish an approved release, serve the exact stapled DMG under `https://voxley.si/downloads/` and its signed feed at `https://voxley.si/appcast.xml`. Publish the DMG before the feed. Editing a signed feed or changing the DMG bytes requires regenerating the signatures.

## Source availability

Copyright © 2026 Protomota, LLC. The source is available to inspect. Third-party components retain their own licenses.
