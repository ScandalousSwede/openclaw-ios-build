# iOS Signing Setup

The `ios-build-ipa.yml` workflow can build two ways:

- With no Apple signing secrets, it keeps the current unsigned Debug IPA path.
- When all three signing secrets are present, it imports the certificate and provisioning profile, generates the Xcode project with manual signing settings, and archives a signed IPA.

## What You Need

For useful CI signing, use an Apple Developer Program account. A free Personal Team can sign locally from Xcode, but CI signing is not practical because Personal Team profiles are short-lived, device-bound, and depend on Xcode account state on a connected Mac.

## Recommended: Ad-Hoc Distribution

Ad-Hoc is the best fit for installing CI-built IPAs on registered test devices. The certificate and provisioning profile are valid much longer than Personal Team signing, and the build can use capabilities such as push notifications when the App ID/profile include them.

### 1. Register Devices

1. Open <https://developer.apple.com/account/resources/devices/list>.
2. Add each iPhone or iPad UDID that should be able to install the IPA.
3. Save the device list before creating the provisioning profile.

### 2. Create and Export the Certificate

1. Open <https://developer.apple.com/account/resources/certificates/list>.
2. Create an iOS Distribution certificate for Ad-Hoc builds.
3. Download the `.cer` file and double-click it on a Mac to add it to Keychain Access.
4. In Keychain Access, find the imported certificate and expand it so the private key is visible.
5. Select the certificate and private key together, then export them as a `.p12` file.
6. Use a real password for the `.p12`; this becomes the GitHub secret `APPLE_CERTIFICATE_PASSWORD`.
7. Base64 encode the `.p12`:

   ```bash
   base64 -i cert.p12 | pbcopy
   ```

8. Add the copied value as the GitHub Actions secret `APPLE_CERTIFICATE_P12_BASE64`.

### 3. Create the Provisioning Profile

1. Open <https://developer.apple.com/account/resources/profiles/list>.
2. Create an Ad-Hoc provisioning profile.
3. Select the OpenClaw App ID used by the iOS project.
4. Select the iOS Distribution certificate you exported above.
5. Select every registered device that should install the IPA.
6. Download the `.mobileprovision` file.
7. Base64 encode it:

   ```bash
   base64 -i profile.mobileprovision | pbcopy
   ```

8. Add the copied value as the GitHub Actions secret `APPLE_PROVISIONING_PROFILE_BASE64`.

## Development Profile Option

A paid Apple Developer account can also use an Apple Development certificate plus a Development provisioning profile. The same three secrets are used. The workflow detects the profile type and chooses `Apple Development` or `Apple Distribution` automatically.

Use Development signing when you need a debug-focused build for specific registered devices. Use Ad-Hoc when you want the most install-friendly signed IPA for normal device testing.

## Free Personal Team

Free Personal Team signing is intentionally not the target for this CI workflow.

- It usually lasts 7 days.
- It often requires Xcode account state and a connected/trusted device.
- It is fragile on GitHub-hosted runners.

Recommendation: use the Apple Developer Program for proper CI signing.

## GitHub Secrets to Add

Open the repository secrets page:

<https://github.com/ScandalousSwede/openclaw-ios-build/settings/secrets/actions>

Add these three repository secrets:

- `APPLE_CERTIFICATE_P12_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_PROVISIONING_PROFILE_BASE64`

The workflow only attempts signing when all three are present. If any one is missing, it falls back to the unsigned IPA path.

## After Adding Secrets

1. Trigger `Build iOS IPA (Debug/Personal Team)` from the Actions tab.
2. Download the `OpenClaw-iOS-IPA` artifact after the run finishes.
3. Install the IPA with AltStore, Sideloadly, Apple Configurator, or another IPA installer that supports signed Ad-Hoc/Development builds.

Ad-Hoc builds install only on devices registered in the Apple Developer portal and included in the provisioning profile. If a device fails to install, confirm its UDID is registered and regenerate the profile.

## Notes for Extensions and Capabilities

The workflow imports one provisioning profile and applies it to the archive. If the project starts signing app extensions, widgets, or watch targets with distinct bundle IDs, each target may need its own provisioning profile. For the main app path, the single profile must match the app bundle ID and include any capabilities you expect to use, such as push notifications.
