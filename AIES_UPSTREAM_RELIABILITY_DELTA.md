# AIES selective upstream reliability delta

## Decision scope

- AIES base: `35ac541decf677497687a9fddf2196c7bd5be044` (`aies/ios-rc1-testflight`)
- Pinned upstream authority: `openclaw/openclaw` tag `v2026.7.1-2`, commit `0790d9f593ad30c940ed93b5872a8cf6d6f3cf8c`
- Import method: semantic ports into the AIES architecture; no merge, rebase, release-range cherry-pick, or branch replacement
- Automatic import horizon: the pinned stable commit above
- Post-stable or beta source imported: **none**
- Implementation packages: three (the authorized maximum)
- Optional stable fixes selected: five (below the authorized maximum of six)

The physically reproduced pairing path is the primary acceptance contract. Upstream issue [#108888](https://github.com/openclaw/openclaw/issues/108888), “iOS node paired via local-discovery approval is permanently unusable (node-only device), surfaced as misleading ‘Credential save failed’,” is used as a regression contract, not as a source import. Its client requirements are implemented in Package B without changing the live gateway protocol.

## Classification summary

| Classification | Count | Items |
|---|---:|---|
| `PORT_REQUIRED` | 8 | #98429, #99572, #100317, #101235, #98066, #92552, #100732, #100328 |
| `ALREADY_PRESENT` | 1 | #100370 |
| `SUPERSEDED_BY_AIES` | 2 | #100277, #98117 |
| `DEFER_NO_CURRENT_REQUIREMENT` | 2 | #98385, #100372 |
| `REJECT_COLLIDES_WITH_AIES` | 0 | none |

Required physical fixes are #98429, #99572, #100317, and #100328 plus the Package-B dual-role pairing contract. The selected useful stable reliability improvements are #101235, #98066, #92552, and #100732. Unrelated feature churn, server/CLI/Control UI changes, broad localization updates, and Watch feature expansion embedded in upstream branch history were not imported.

## Package map and rollback

### Package A — pairing, TLS trust, route selection, and setup ownership

Purpose: repair the reproduced sequence in which the QR scanner reaches fingerprint verification but the actionable trust alert never appears, while keeping TLS fail-closed.

Resulting commits:

- `73eb4e8fdc` — `fix(ios): harden setup routes and TLS trust`
- `dc81c4a017` — `fix(ios): defer QR setup until scanner dismissal`
- `ad50a951ca` — `fix(ios): make root own setup-link delivery`
- `54cbc43ce9` — `fix(ios): fail closed across TLS trust handoff`
- `36b380643b` — `fix(ios): make trusted setup admission atomic`

Rollback: revert the Package-A commits in reverse order. No Package-B or Package-C source is required to remove Package A.

### Package B — dual-role pairing and honest connection state

Purpose: require a validated node-and-operator bootstrap result; preserve role-scoped credentials; bind lifecycle work to exact route ownership; and report node and operator health separately.

Resulting commits:

- `575855468c` — `fix(ios): require dual-role mobile pairing`
- `dd50585dcf` — `fix(ios): fence reconnect and APNs side effects`
- `83c06a7bd4` — `fix(ios): fence dual-role recovery to exact routes`
- `43b567b6af` — `fix(ios): bind dual-role handoff to one route`

Rollback: revert Package-B commits without reverting Package A. Package B owns no signing, package-authority, or release-policy state.

### Package C — bounded stable iOS reliability delta

Purpose: replace scheduler-count WatchConnectivity activation polling with a delegate-completed bounded activation gate, without importing persistent Watch reply/outbox feature work.

Resulting commit:

- `5e26d997df` — `fix(ios): gate Watch messaging on activation`

Rollback: revert the Package-C commit. The aggregate package-authority record changes only because `project.yml` is a declared input; package identities and pins are unchanged.

### Qualification support

- `b1b8f54fda` — `test(ios): qualify reliability sync surfaces`
- Scope: `.github/workflows/ios-build-ipa.yml` only; selects the new parser, TLS, scanner, setup ownership, dual-role, route-fencing, APNs, and Watch activation coverage in the existing credential-free lane.
- This is qualification/tooling support, not a fourth implementation package and not an upstream product semantic port.
- Rollback: revert `b1b8f54fda`; product/package commits remain independently reviewable.

## Inspected upstream items

### PR #98429 — fix(ios): classify TLS fingerprint timeouts

- Upstream PR: [#98429](https://github.com/openclaw/openclaw/pull/98429)
- Stable merge: `0c7bac34ae6822aadbb62d9be10030b57452ca2e`
- Primary source commit: `f2a72a02ef295a2c60990b49086c9264974e8703`
- Upstream paths: `GatewayConnectionController.swift`, `GatewayTrustPromptAlert.swift`, `SettingsProTabActions.swift`, `GatewayConnectionSecurityTests.swift`, `RootTabsSourceGuardTests.swift`, `SwiftUIRenderSmokeTests.swift`
- AIES paths: `apps/ios/Sources/Gateway/GatewayConnectionController.swift`, `apps/ios/Sources/Gateway/GatewayTrustPromptAlert.swift`, `apps/ios/Tests/GatewayConnectionSecurityTests.swift`, `apps/ios/Tests/SwiftUIRenderSmokeTests.swift`
- Current/base behavior: fingerprint acquisition failure and timeout state did not reliably retain an actionable typed trust continuation for presentation.
- Upstream behavior: classifies fingerprint timeouts and keeps the trust decision explicit.
- Physical relevance: **required physical fix**; the phone reached fingerprint verification but no Cancel/Trust alert appeared.
- Classification: `PORT_REQUIRED`
- Collision risk: medium; AIES has stronger pin persistence and gateway-identity fencing.
- Action: ported the timeout/error semantics and typed prompt contract while preserving AIES fail-closed pinning, certificate-rotation handling, and exact attempt ownership.
- Tests: TLS timeout classification, accepted/rejected/rotated fingerprint, prompt render/source guards, and stale-attempt rejection.
- Resulting commits: `73eb4e8fdc`, `54cbc43ce9`, `36b380643b`
- Rollback commit: revert the Package-A commits in reverse order.

### PR #99572 — fix(ios): defer QR pairing after scanner dismissal

- Upstream PR: [#99572](https://github.com/openclaw/openclaw/pull/99572)
- Stable merge: `a320f775f0f3f058b612da8b1fbc2adaebca097d`
- Primary source commits inspected: `5d9a2aaaca07d1206177cb4ab495706d3b7a0d79`, `3ec7a1a178cad7420c14d750bdd6c63a356c4525`, `15422c886c555b955cd6fdc573287f228ac17920`, `b66b22c55ab27ba89847081551915277676cc70e`
- Upstream paths: `QRScannerView.swift`, `SettingsProTab.swift`, `SettingsProTabActions.swift`, `OnboardingWizardView.swift`, `RootTabs.swift`, and their scanner/security tests. The PR’s unrelated server, Watch, localization, and synchronization changes were not imported.
- AIES paths: `apps/ios/Sources/Onboarding/QRScannerView.swift`, `apps/ios/Sources/Onboarding/OnboardingWizardView.swift`, `apps/ios/Sources/Design/SettingsProTab.swift`, `apps/ios/Sources/Design/SettingsProTabActions.swift`, `apps/ios/Sources/RootTabs.swift`, `apps/ios/Tests/QRScannerResultHandoffTests.swift`
- Current/base behavior: pairing/trust work could begin while the VisionKit scanner sheet and capture stack were still dismissing.
- Upstream behavior: one typed result owns the scan, capture stops, the sheet dismisses, and pairing resumes only after the presentation stack settles.
- Physical relevance: **required physical fix**; directly explains a trust alert hidden or dropped behind scanner teardown.
- Classification: `PORT_REQUIRED`
- Collision risk: medium; AIES has two setup owners and stronger setup-attempt fencing.
- Action: ported a first-result-wins typed handoff into both onboarding and Settings, with cancellation and attempt identity retained. No arbitrary trust bypass was added.
- Tests: scanner starts after presentation, stops before dismissal, one-shot delivery, cancellation, stale scan rejection, onboarding ownership, and post-dismiss trust presentation.
- Resulting commits: `dc81c4a017`, `54cbc43ce9`, `36b380643b`
- Rollback commit: revert the Package-A commits in reverse order.

### PR #100317 — fix(pairing): advertise reachable Tailnet routes

- Upstream PR: [#100317](https://github.com/openclaw/openclaw/pull/100317)
- Stable merge: `862de9f1a1c2ecc0ae87bc7e14fe2af275fafcac`
- Primary source commits inspected: `b06e4bc3f4c6e30e4a2be685353014aadc8982b3` and iOS stale-probe commit `dbd0b8f295d3e49ce8c229991ea8510d32b43fa0`
- Upstream paths: `DeepLinks.swift`, `GatewayConnectionController.swift`, onboarding/Settings setup surfaces, setup models, and route-security tests; server/CLI/plugin/UI producers were inspected only for schema compatibility.
- AIES paths: `apps/shared/OpenClawKit/Sources/OpenClawKit/DeepLinks.swift`, `apps/ios/Sources/Gateway/GatewayConnectionController.swift`, related setup/security tests.
- Current/base behavior: setup parsing privileged a single endpoint and did not fully enforce a bounded ordered candidate contract across setup input forms.
- Upstream behavior: setup data can advertise ordered reachable URLs, including Tailnet Serve, with stale probe cancellation.
- Physical relevance: **required physical fix**; the working endpoint is WSS over Tailnet Serve at implicit/explicit port 443.
- Classification: `PORT_REQUIRED`
- Collision risk: medium; the live gateway already has modern server-side route support, while AIES has stricter local/LAN security policy.
- Action: ported only the iOS/shared-client schema and bounded ordered selection. Supports unpadded Base64URL, raw JSON/copied text/QR input, implicit and explicit WSS 443, and rejects insecure remote `ws://`; no server or CLI source was imported.
- Tests: implicit/explicit 443, ordered fallback, bounded candidate count, insecure remote rejection, accepted private-LAN policy, and stale probe ownership.
- Resulting commits: `73eb4e8fdc`, `54cbc43ce9`, `36b380643b`
- Rollback commit: revert the Package-A commits in reverse order.

### PR #101235 — fix ios qr scanner lifecycle

- Upstream PR: [#101235](https://github.com/openclaw/openclaw/pull/101235)
- Stable merge: `632efa2d7343f44408c3e25b1de20e7de889534e`
- Source commits: `0ae1e35ccb58299963ad809ec3fd2cb50e9c12f7`, `892977020477ce43c553add34da4bd9574235802`
- Upstream paths: `apps/ios/Sources/Onboarding/QRScannerView.swift`, `apps/ios/Tests/RootTabsSourceGuardTests.swift`
- AIES paths: `apps/ios/Sources/Onboarding/QRScannerView.swift`, `apps/ios/Tests/QRScannerResultHandoffTests.swift`
- Current/base behavior: scanner activation/teardown could overlap UIKit presentation changes.
- Upstream behavior: start capture after presentation; stop during disappearance and dismantle; deliver once.
- Physical relevance: **useful reliability improvement** adjacent to the reproduced scanner/prompt failure.
- Classification: `PORT_REQUIRED`
- Collision risk: low.
- Action: incorporated into the Package-A scanner handoff rather than copied as a parallel scanner implementation.
- Tests: VisionKit lifecycle source guard, stop-before-result, duplicate producer rejection, and cancellation.
- Resulting commits: `dc81c4a017`, `36b380643b`
- Rollback commit: revert the Package-A commits in reverse order.

### PR #100328 — fix(ios): own gateway setup deep-link delivery

- Upstream PR: [#100328](https://github.com/openclaw/openclaw/pull/100328)
- Stable merge: `9ba14b80ab9b970ea4ba98dc551f3deb1f9cd1d8`
- Source commit: `999ab7e210d902e9e3209685a2f35237fc9846a3`
- Upstream paths: `SettingsProTab.swift`, `SettingsProTabActions.swift`, `RootTabs.swift`, `DeepLinks.swift`, and delivery tests.
- AIES paths: `apps/ios/Sources/RootTabs.swift`, `apps/ios/Sources/Design/SettingsProTab.swift`, `apps/ios/Sources/Design/SettingsProTabActions.swift`, `apps/ios/Tests/GatewaySetupDeliveryOwnershipTests.swift`
- Current/base behavior: both a hidden Settings view and the visible onboarding owner could consume the same model-level setup link.
- Upstream behavior: the visible presentation owner consumes once and hands an immutable request to the destination UI.
- Physical relevance: **required physical fix**; a hidden consumer can remove the setup attempt before its trust alert becomes visible.
- Classification: `PORT_REQUIRED`
- Collision risk: medium; AIES intentionally permits visible onboarding to own setup while it is presented.
- Action: RootTabs owns Settings delivery; onboarding retains explicit priority; Settings no longer consumes model state directly.
- Tests: source guard proves one RootTabs consumer for Settings, immutable request handoff, acknowledgement, and retained onboarding ownership.
- Resulting commits: `ad50a951ca`, `36b380643b`
- Rollback commit: revert the Package-A commits in reverse order.

### PR #98066 — keep iOS LAN QR pairing authenticated after bootstrap

- Upstream PR: [#98066](https://github.com/openclaw/openclaw/pull/98066)
- Stable merge: `155c2f4e7eb051b73f0a4bd38f674b4113be370a`
- Source commit: `a3e609836b49a448cb9aa20970b9c3462ee44014`
- Upstream paths: `GatewayChannel.swift`, `GatewayNodeSessionTests.swift`
- AIES paths: `GatewayChannel.swift`, `GatewayNodeSession.swift`, `DeviceAuthStore.swift`, new `GatewayBootstrapHandoff.swift`, and `GatewayNodeSessionTests.swift`
- Current/base behavior: bootstrap authentication could be consumed before the durable role credentials needed for reconnect were validated and persisted.
- Upstream behavior: persists the authenticated handoff token before a LAN reconnect.
- Physical relevance: **useful reliability/security improvement** and a prerequisite for an honest dual-role success receipt.
- Classification: `PORT_REQUIRED`
- Collision risk: high but bounded; AIES has role-scoped auth, stable gateway identity, route generations, and a stricter persistence boundary.
- Action: ported the semantic requirement into a two-role, exact-owner bootstrap receipt. Node and operator tokens/scopes are validated together; a partial result is not mobile-setup success and secrets are excluded from diagnostics.
- Tests: complete dual-role issuance, node-only, missing operator token, missing each required operator scope, unexpected overgrant, persistence failure, exact route retirement, and reconnect auth.
- Resulting commits: `575855468c`, `83c06a7bd4`, `43b567b6af`
- Rollback commit: revert the Package-B commits in reverse order.

### PR #92552 — force stale foreground gateway reconnects

- Upstream PR: [#92552](https://github.com/openclaw/openclaw/pull/92552)
- Stable merge: `e58310b000bdd811d113cbe71bdce7c8bdeeb80a`
- Source commit: `75e220a720f69594da8ae2b2e4f80ea4c5e72560`
- Upstream paths: `NodeAppModel.swift`, `GatewayConnectionControllerTests.swift`
- AIES paths: `apps/ios/Sources/Model/NodeAppModel.swift`, `apps/ios/Tests/GatewayConnectionControllerTests.swift`, `GatewayNodeSession.swift` tests.
- Current/base behavior: foreground recovery could accept stale connected booleans or allow old health/reconnect work to affect a replacement route.
- Upstream behavior: forces reconnect when foreground health is stale.
- Physical relevance: **useful reliability improvement** for the observed node-online/operator-never-attempted state.
- Classification: `PORT_REQUIRED`
- Collision risk: high; route-unbound reconnects would violate AIES S1/S3 ownership fencing.
- Action: ported the foreground-recovery intent with stronger AIES semantics: health, disconnect, reconnect, event delivery, and deferred work are bound to captured node/operator routes and stable gateway identity. An old route cannot disconnect or terminally block its successor.
- Tests: forced stale reconnect, user-selected replacement protection, route-bound event/lifecycle operations, operator reconnect, and route-generation outbox guards.
- Resulting commits: `575855468c`, `dd50585dcf`, `83c06a7bd4`, `43b567b6af`
- Rollback commit: revert Package B in reverse order.

### PR #100732 — harden Apple Watch pairing activation

- Upstream PR: [#100732](https://github.com/openclaw/openclaw/pull/100732)
- Stable merge: `8d1668c441a98e3b319c405ca8c2d81c9f19d6db`
- Source commit: `c760161160f43f95c5d8d347e038dd38ba5ced91`
- Upstream paths: `WatchConnectivityTransport.swift`, `WatchSessionActivationGate.swift`, `WatchConnectivityReceiver.swift`, `WatchSessionActivationGateTests.swift`, `project.yml`
- AIES paths: the corresponding phone service and Watch-extension receiver, new shared activation gate/tests, `project.yml`, package-authority input hash, and credential-free qualification selection.
- Current/base behavior: send readiness used eight scheduler-count polls of 100 ms and could observe pairing/install/reachability before activation completed.
- Upstream behavior: a delegate-completed, bounded, shared activation wait supports concurrent callers, failure, retry, and deactivation.
- Physical relevance: **useful reliability improvement** with bounded collision.
- Classification: `PORT_REQUIRED`
- Collision risk: low for activation; persistent reply delivery is explicitly outside this port.
- Action: ported the activation gate and lifecycle callbacks only. Status does not claim paired/installed/reachable until activation; no provider, routing, or Watch reply persistence behavior is added.
- Tests: concurrent waiter coalescing, bounded timeout/retry, error fan-out, deactivation reset, late-generation fencing, phone/watch source guards, and project inclusion.
- Resulting commit: `5e26d997df`
- Qualification support commit: `b1b8f54fda`
- Rollback commit: revert `5e26d997df` as Package C.

### PR #100370 — avoid inactive Voice Wake audio startup

- Upstream PR: [#100370](https://github.com/openclaw/openclaw/pull/100370)
- Stable merge: `444d54c5389aa51d6d03481d340c91dc3d277b99`
- Source commits: `3b98711fe1daefbc116c0fa73e0ee0bc4c1413b1`, `4dddf96269a8cfb489c1dd4a2b557b256c0aa681`, `33f9d08f5b24df038189e616e900e29ec611cdef`
- Upstream paths: `VoiceWakeManager.swift`, `OpenClawApp.swift`, `NodeAppModel.swift`, tests.
- AIES paths inspected: the same lifecycle/voice surfaces and existing Talk/voice-wake tests.
- Current behavior: AIES already suspends voice wake on background/external capture/Talk/PTT and resumes only through explicit active lifecycle reconciliation.
- Upstream behavior: prevents inactive-scene audio startup.
- Physical relevance: useful audio reliability, but the invariant is already present.
- Classification: `ALREADY_PRESENT`
- Collision risk: high if copied, because AIES TTS-D1 and Talk/PTT audio ownership are stronger.
- Action: no source import; retained existing AIES behavior and tests.
- Resulting commit: none.

### PR #100277 — restore in-flight runs after reconnect

- Upstream PR: [#100277](https://github.com/openclaw/openclaw/pull/100277)
- Stable merge: `443c582949e3ec6dfc197ea1d33913a7cd7448f3`
- Source commits: `7c4dbf88d8071090177cb4be1f02261dd5bc6560`, `31cf8b9416c10797dce7e3055cad634add04c0d4`
- Upstream paths: iOS chat transport/view model and shared chat reconciliation.
- AIES paths inspected: `IOSGatewayChatTransport.swift`, `OpenClawChatOutboxCoordinator.swift`, `OpenClawChatOutboxStorage.swift`, `ChatViewModel.swift`, and reliability tests.
- Current behavior: AIES S2/S3 already reconciles canonical history under route/run identity, owns durable typed sends, and fences ambiguous/replayed results by gateway and route generation.
- Upstream behavior: restores in-flight UI runs from gateway history after reconnect.
- Physical relevance: useful reliability but weaker than the AIES durable ownership contract.
- Classification: `SUPERSEDED_BY_AIES`
- Collision risk: high; direct import could create a second reconciliation owner or duplicate a durable send.
- Action: no source import; retained S2/S3 behavior and regression coverage.
- Resulting commit: none.

### PR #98117 — avoid transient duplicate final replies

- Upstream PR: [#98117](https://github.com/openclaw/openclaw/pull/98117)
- Stable merge: `5a5913a98b031e4364be68a1796f39fe62fd1d09`
- Source commits: `1ee22120be3b794a9c13094c4a04d766cfbac840`, `71be307332388f17806a8ed4a9169f75985cf200`, `526f0aba3127211f0422a59cd59a0c485b0adcc6`
- Upstream paths: `ChatViewModel.swift`, `ChatViewModelTests.swift`
- AIES paths inspected: the shared Chat view model plus S2/S3/S3.1 identity and foreign-final reliability suites.
- Current behavior: AIES reconciliation is scoped by session, run, gateway identity, and durable owner; foreign terminal events cannot clear or present as the authoritative run.
- Upstream behavior: scopes final-message reconciliation to avoid a transient duplicate.
- Physical relevance: useful chat integrity, already covered by stronger AIES semantics.
- Classification: `SUPERSEDED_BY_AIES`
- Collision risk: high if layered on the AIES identity model.
- Action: no import; preserve exact raw-run/foreign-final and durable-outbox assertions.
- Resulting commit: none.

### PR #98385 — actionable mobile protocol mismatch recovery

- Upstream PR: [#98385](https://github.com/openclaw/openclaw/pull/98385)
- Stable merge: `ad59492d3ca9261a941721c864b2bc2278b63957`
- Source commits: `5223dcbf5626cd7cc51eb1eeb926bde9a532940d`, `027ba354a6b754c56a189805cf9eb3f904b96601`, `6f5929da48c0477e904a20c659e1fd10f1dc5d12`
- Upstream paths: gateway error/problem mapping, onboarding/Settings/RootTabs actions, and tests.
- AIES paths inspected: `GatewayConnectionProblem.swift`, `GatewayConnectionIssue.swift`, `GatewayProblemView.swift`, quick setup surfaces, and protocol diagnostics.
- Current behavior: AIES already maps structured connection problems and preserves pairing/TLS ownership; no protocol-mismatch failure was reproduced in this tranche.
- Upstream behavior: provides actionable upgrade/retry recovery for a mobile/server protocol mismatch.
- Physical relevance: useful reliability, but not required by current physical evidence.
- Classification: `DEFER_NO_CURRENT_REQUIREMENT`
- Collision risk: medium because problem actions intersect the newly ported trust/pairing state machine.
- Action: defer until an exact protocol-mismatch requirement exists; no feature churn imported.
- Deferral reason: bounded sync prioritizes the reproduced pairing failure and avoids widening setup recovery UI without a regression contract.

### PR #100372 — persist queued Watch replies

- Upstream PR: [#100372](https://github.com/openclaw/openclaw/pull/100372)
- Stable merge: `70f2bef6b4cf04792f5f15fc12a9fafafa5771cc`
- Source commits: `725615af2bca87291eecf4cee29b432fa81a29ed`, `ff74edbb40b5ffccd223b9563045d3a07adfe67f`
- Upstream paths: `NodeAppModel.swift`, `WatchReplyCoordinator.swift`, Watch messaging services/payload codec, Watch receiver/inbox, and tests.
- AIES paths inspected: `NodeAppModel.swift`, Watch transport/receiver/inbox, node route/session, and S1/S3 route-generation tests.
- Current behavior: queued Watch replies are not a fully persistent, gateway-bound durable outbox; activation is being fixed separately by #100732.
- Upstream behavior: persists queued replies across lifecycle and upgrades.
- Physical relevance: useful Watch reliability, but not part of the reproduced pairing defect.
- Classification: `DEFER_NO_CURRENT_REQUIREMENT`
- Collision risk: **high**. A direct port changes reply ownership across stable gateways, route generations, app restarts, and immediate/queued ambiguity. It overlaps the AIES S1/S3 durable-delivery boundary and can duplicate, reorder, or deliver to a successor gateway without a dedicated design.
- Action: explicitly defer. Package C ports activation only and restores/retains the existing reply semantics rather than claiming persistence.
- Required future regression contract: persistent reply identity, stable-gateway binding, route-generation fencing, exactly-once ambiguity handling, ordering across immediate and queued paths, and migration of pre-upgrade replies.
- Deferral reason: it requires a separately qualified Watch durable-outbox package, not a small activation reliability port.

## Package-B AIES-specific physical contract

Issue #108888 and the physical build-72 state establish requirements not safely represented by a direct upstream patch:

- mobile setup succeeds only after node and operator tokens are both present and the operator role includes `operator.read`, `operator.write`, and `operator.talk.secrets` (plus `operator.approvals` when issued);
- node-only issuance is an honest setup failure, not a keychain failure;
- node and operator state are projected separately;
- Agents is “unavailable” until `agents.list` succeeds, rather than authoritative zero;
- Talk distinguishes operator unavailability from a server with no Talk configuration;
- Chat/outbox blocking text identifies the missing operator, scope, route, gateway identity, or actual offline condition;
- reconnect and callback work is exact-route owned, so a retired route cannot mutate, disconnect, or block its successor.

The implementation remains client-only. It does not remove the old sideloaded server device, alter gateway security, call a live gateway, or weaken role ceilings.

## Feature-churn boundary

The following were inspected only far enough to exclude them:

- server, CLI, device-pair plugin, and Control UI changes in #100317;
- unrelated server/APNs/Watch/localization changes carried by the long-lived #99572 PR branch;
- ClickClack, dashboard, localization, and other unrelated changes present around #100370;
- persistent Watch reply feature work in #100372;
- broad chat/UI restoration changes in #100277 beyond the specific reliability semantic.

No beta/prerelease commit was imported. The `2026.9.1-beta.1` line was not used as source authority.

## Qualification binding

All three packages and the credential-free qualification selection now have exact commits. The local release-tooling gate passed `184/184`. macOS Swift/Xcode execution, its run/evidence receipts, deterministic XcodeGen verification, and the unsigned five-target archive remain pending. The remaining gate includes package/conformance, Shared and iOS reliability, Talk and Chat durable outbox suites, parser/TLS/scanner/pairing/reconnect/APNs/Watch tests, two deterministic XcodeGen passes, and an unsigned five-target archive with UUID/dSYM/package provenance evidence.

Until that seal is attached, this report records the source-selection decision and implementation mapping; it does not claim promotion, signing, upload, Apple mutation, gateway mutation, or physical acceptance.
