# iOS Crash Handoff

Use this contract for a physical-device crash only when the installed binary came from the attributable GitHub Actions build described below (or that exact binary was re-signed without rebuilding it). A report is complete only when it identifies the exact binary and includes enough bounded evidence to correlate the crash with connection and message lifecycle metadata.

The credential-free workflow produces an unsigned compile/archive artifact, while the protected internal-TestFlight lane injects and verifies the same provenance before upload. Local or otherwise unverified builds remain **unknown installed builds** unless their exact binary identity is independently bound to retained artifacts.

## Required artifacts

Provide all of the following:

1. The `.ips` device crash report.
2. `OpenClaw-build-manifest.json` from the same GitHub Actions build.
3. The matching `OpenClaw.xcarchive.zip` and `OpenClaw-dSYMs.zip` artifact names, download links, or archived copies.
4. Device model and iOS version.
5. Approximate reproduction timestamp, including timezone.
6. A short description of what the user was doing immediately before the crash.
7. `OpenClaw-Crash-Diagnostics.json`, prepared after relaunch from **Settings → Diagnostics → Prepare Crash Export → Share Crash Export**.

The CI manifest is the artifact authority. Match its `git_sha`, `archive_uuid`, and `dsym_uuids` to the uploaded archive and dSYM artifacts. The nested on-device manifest uses the distinct `argus.openclaw-ios.runtime-build-manifest.v1` schema: it reads every `LC_UUID` from the installed main executable into `main_binary_uuids` and repeats those UUIDs in `dsym_uuids` as lookup keys for that main executable only. Runtime `dsym_uuids` are therefore derived from the linked executable, not from inspecting dSYM files on the device, and do not claim the CI manifest's complete multi-target dSYM inventory. Check `runtime_uuid_source` and `runtime_uuid_status` before using them; only `runtime_main_executable_lc_uuid` plus `observed` represents a successful read. An unavailable, unreadable, UUID-less, or malformed executable produces empty UUID arrays and an explicit non-observed status.

## Diagnostic export boundary

The on-device `argus.openclaw-ios.crash-diagnostic.v2` export is capped at 256 KiB and contains only allowlisted metadata from a versioned protected rolling log. Diagnostic-event v2 adds launch/TTS metadata while retaining read compatibility with v1 records. Legacy raw-log files are never imported:

- app and scene lifecycle;
- process ID and a hashed per-process launch identifier for epoch grouping;
- socket, route, reconnect, and Live Activity generations;
- network interface transitions;
- hashed session, run, message, event, and operation identities;
- event sequence and stream;
- metadata-only TTS boundaries, including generation, sanitized provider/decoder/route tokens, byte counts, sample rate, and duration;
- exact embedded build provenance;
- installed main-executable architecture and `LC_UUID` identity, with runtime source and read status;
- device model and iOS version.

Selected pre-risk and terminal TTS boundary records wait at most 100 milliseconds for the protected rolling-log queue before product execution continues. The drain is skipped when already on the writer queue, preventing a diagnostic deadlock. This reduces the chance that an abrupt process death merely strands the final boundary in memory, but remains best-effort diagnostic persistence—not an exception handler or an Apple crash stack.

`diagnostic_log_flush_status` records whether the final one-second queue drain and event snapshot completed. A timeout or unavailable log produces an empty event snapshot plus an explicit status; export success alone never implies that the queue was fully drained.

The export does not include APNs tokens, credentials, gateway addresses, prompts, transcript bodies, message contents, raw audio, tool arguments, tool results, or private error text. Do not substitute the raw rolling log for this export.

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
2. Compare the crash report binary UUID with the runtime export's `main_binary_uuids` only when `runtime_uuid_status` is `observed`.
3. Compare that UUID with the CI manifest's `dsym_uuids`, then confirm the manifest SHA and build number match the on-device diagnostic export.
4. Symbolicate with the matching `.xcarchive` or dSYM set.
5. Correlate the crash timestamp with the sanitized event window.

If any identity does not match, classify the crash as an unknown installed build instead of attributing it to the current source tree.
