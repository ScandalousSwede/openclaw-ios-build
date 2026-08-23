# iOS Crash Handoff

Use this contract for a physical-device crash only when the installed binary came from the attributable GitHub Actions build described below (or that exact binary was re-signed without rebuilding it). A report is complete only when it identifies the exact binary and includes enough bounded evidence to correlate the crash with connection and message lifecycle metadata.

The current workflow produces an unsigned compile/archive artifact. Local Fastlane and TestFlight builds do not yet inject or verify the same provenance contract. Until a signed multi-bundle pipeline does so, classify crashes from those builds as **unknown installed build** rather than associating them with a CI source SHA.

## Required artifacts

Provide all of the following:

1. The `.ips` device crash report.
2. `OpenClaw-build-manifest.json` from the same GitHub Actions build.
3. The matching `OpenClaw.xcarchive.zip` and `OpenClaw-dSYMs.zip` artifact names, download links, or archived copies.
4. Device model and iOS version.
5. Approximate reproduction timestamp, including timezone.
6. A short description of what the user was doing immediately before the crash.
7. `OpenClaw-Crash-Diagnostics.json`, prepared after relaunch from **Settings → Diagnostics → Prepare Crash Export → Share Crash Export**.

The CI manifest is the symbolication authority. Match its `git_sha`, `archive_uuid`, and `dsym_uuids` to the uploaded archive and dSYM artifacts. The runtime manifest inside the device export intentionally leaves `dsym_uuids` empty because those UUIDs only exist after linking; its archive UUID, source SHA, version, and build number identify the matching CI manifest.

## Diagnostic export boundary

The on-device export is capped at 256 KiB and contains only allowlisted metadata from a versioned protected rolling log. Legacy raw-log files are never imported:

- app and scene lifecycle;
- socket, route, reconnect, and Live Activity generations;
- network interface transitions;
- hashed session, run, message, event, and operation identities;
- event sequence and stream;
- exact embedded build provenance;
- device model and iOS version.

It does not include APNs tokens, credentials, gateway addresses, prompts, transcript bodies, message contents, tool arguments, tool results, or private error text. Do not substitute the raw rolling log for this export.

## CI artifact contract

The `Build iOS IPA (Debug/Unsigned)` workflow retains these unsigned artifacts for 90 days:

- `OpenClaw-iOS-IPA-<run>-<attempt>`;
- `OpenClaw-iOS-xcarchive-<run>-<attempt>`;
- `OpenClaw-iOS-dSYMs-<run>-<attempt>`;
- `OpenClaw-iOS-build-manifest-<run>-<attempt>`.

Copy the archive, dSYMs, and manifest to the long-lived AIES evidence store before their GitHub retention window expires. The manifest includes SHA-256 hashes for the IPA, archive ZIP, and dSYM ZIP so copied artifacts can be verified without relying on filenames.

Do not install or distribute the unsigned IPA as-is. Signed app/share/widget/Watch provisioning is a separate gate and must preserve the embedded build metadata and linked Mach-O UUIDs.

## Symbolication check

Before diagnosing source behavior:

1. Verify artifact SHA-256 values against the build manifest.
2. Compare the crash report binary UUID with `dsym_uuids`.
3. Confirm the manifest SHA and build number match the on-device diagnostic export.
4. Symbolicate with the matching `.xcarchive` or dSYM set.
5. Correlate the crash timestamp with the sanitized event window.

If any identity does not match, classify the crash as an unknown installed build instead of attributing it to the current source tree.
