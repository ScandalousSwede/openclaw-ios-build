# AIES internal TestFlight diagnostic lane

This lane is intentionally separate from the existing unsigned diagnostic build and the normal
relay-backed beta lane. It builds the complete iPhone + Share + Activity + Watch package, verifies
every signed bundle, proves the Argus direct-push contract in both the archive and final IPA, waits
for App Store Connect processing, and exports with Apple's `testFlightInternalTestingOnly` flag.
That flag makes the build ineligible for external TestFlight or App Store release; the upload also
keeps external distribution and beta review disabled.

## One-time protected environment setup

Create the GitHub environment `aies-testflight-internal` with required reviewers, prevent
self-review where the account supports it, and restrict deployment branches to
`aies/ios-tts-d1-testflight`. Add these environment variables:

- `AIES_TESTFLIGHT_INTERNAL_ENABLED=true`
- `AIES_INTERNAL_TESTER_GROUP` — the exact internal App Store Connect group Ethan belongs to
- `APPLE_TEAM_ID`
- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `APP_BUNDLE_ID=ai.openclaw.client`
- `APP_STORE_CONNECT_APP_ID`

Add one environment secret:

- `ASC_PRIVATE_KEY_P8` — the App Store Connect API private key in PEM form

The Argus APNs provider key is a server credential. It must not be stored in GitHub or reused as the
App Store Connect build credential.

The first signed run attempts Xcode automatic App Store distribution signing for all five bundles.
If Xcode reports that an Apple Distribution identity/private key or a provisioning profile cannot be
created or downloaded, stop and provision that exact missing asset. Do not reuse an unidentified
historical certificate archive.

## Dispatch

Run `Build iOS IPA (Unsigned / Protected Internal TestFlight)` on the isolated branch with:

- `distribution=signed-internal-testflight`
- `expected_git_sha=<exact 40-character workflow SHA>`
- `confirm_internal_only=true`

Tags and detached workflow refs are rejected. Third-party workflow actions are pinned to immutable
commit SHAs; the local Node setup is invoked with its unpinned optional cache actions disabled. The
App Store Connect key is materialized only after credential-free project generation,
Swift builds, and focused simulator tests; the runner removes both the bounded key file and Fastlane's
bounded key copy on every success or failure path.

The job fails before upload unless the checkout, protected metadata, private key, complete bundle
set, production APNs entitlement, direct registration mode, empty relay URL, build provenance,
archive, dSYMs, and manifest all verify. The relay value must be the exact empty string. Verification
requires exactly the main app, Share extension, Activity extension, Watch app, and Watch extension at
their expected bundle paths. It also binds every code-signing leaf certificate to that bundle's trusted
provisioning profile, requires `beta-reports-active=true`, proves every signed entitlement is
profile-authorized, and binds each of the five exported executables to the archive and matching dSYM by
signature-stripped hash plus architecture-qualified Mach-O UUID. After processing, the lane queries the
exact App Store Connect app/version/build and fails unless `processingState=VALID` and
`buildAudienceType=INTERNAL_ONLY`. Any bounded archive, symbol, or evidence artifact that exists is
uploaded before final credential cleanup, including post-upload validation failures. Artifacts are
retained for 90 days.

Fastlane does not reliably assign an uploaded build to an internal group by group name. After the
delivery report says `uploaded_processing_complete`, and records `asc_processing_state=VALID` plus
`asc_build_audience_type=INTERNAL_ONLY`, perform one App Store Connect action: assign
that exact version/build to `AIES_INTERNAL_TESTER_GROUP` and confirm Ethan is a member. Do not add
external testers or submit the build for public review.

## Before Ethan installs

1. Match the TestFlight version/build to the build manifest's exact Git SHA.
2. Confirm the signing report shows the expected team, all five bundle IDs, and
   `aps-environment=production` for the main app. Confirm signer/profile trust, entitlement
   authorization, executable/dSYM binding, and `testflight_internal_testing_only=true` in the delivery
   report. Confirm `external_distribution_requested=false` and `beta_review_requested=false`; these
   state release intent, while the App Store Connect audience field is the observed server proof.
3. Retain the matching archive and dSYMs.
4. Export diagnostics from the currently installed development build.
5. Treat in-place update and local-data preservation as unproven; the signed bundle/team report is
   the source of truth for whether iOS can update the existing install.

This lane authorizes only an internal diagnostic upload. It does not deploy Argus, release publicly,
or establish conference-primary acceptance without physical-device testing.
