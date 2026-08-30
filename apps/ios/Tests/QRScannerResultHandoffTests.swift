import Foundation
import Testing
@testable import OpenClaw

@MainActor
struct QRScannerResultHandoffTests {
    @Test func visionScannerLifecycleStartsOnlyAfterPresentationAndStopsBeforeDismissal() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Onboarding/QRScannerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let makeStart = try #require(source.range(of: "func makeUIViewController"))
        let updateStart = try #require(source.range(of: "func updateUIViewController"))
        let makeBody = source[makeStart.lowerBound..<updateStart.lowerBound]
        #expect(!makeBody.contains("startScanning()"))
        #expect(makeBody.contains("QRScannerContainerViewController"))

        let didAppear = try #require(source.range(of: "override func viewDidAppear"))
        let willDisappear = try #require(source.range(of: "override func viewWillDisappear"))
        let stopCapture = try #require(source.range(of: "func stopScannerCapture"))
        #expect(source[didAppear.lowerBound..<willDisappear.lowerBound].contains("startScanningIfNeeded()"))
        #expect(source[willDisappear.lowerBound..<stopCapture.lowerBound].contains("stopScannerCapture()"))
        #expect(source.contains("dismantleUIViewController"))
        #expect(source.contains("scanner.stopScannerCapture()"))

        let deliverStart = try #require(source.range(of: "private func deliver"))
        let didRemoveStart = try #require(source.range(of: "func dataScanner(_: DataScannerViewController, didRemove"))
        let deliverBody = source[deliverStart.lowerBound..<didRemoveStart.lowerBound]
        let stopIndex = try #require(deliverBody.range(of: "scanner.stopScanning()"))
        let resultIndex = try #require(deliverBody.range(of: "self.parent.onResult(result)"))
        #expect(stopIndex.lowerBound < resultIndex.lowerBound)

        let iosRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Design/SettingsProTab.swift"),
            encoding: .utf8)
        let onboardingSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Onboarding/OnboardingWizardView.swift"),
            encoding: .utf8)
        let rootSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/RootTabs.swift"),
            encoding: .utf8)
        #expect(settingsSource.contains("onDismiss: { self.processQueuedScannerResult() }"))
        #expect(onboardingSource.contains("onDismiss: { self.processQueuedScannerResult() }"))
        #expect(rootSource.contains(".gatewayTrustPromptAlert(isEnabled: !self.showOnboarding)"))
    }

    @Test func scannerOwnersPreserveExistingGatewayUntilAReplacementResultIsAccepted() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let iosRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()

        let settingsSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Design/SettingsProTabActions.swift"),
            encoding: .utf8)
        let settingsOpenStart = try #require(settingsSource.range(of: "func openGatewayQRScanner()"))
        let settingsOpenEnd = try #require(
            settingsSource.range(of: "func handleScannedGatewayLink", range: settingsOpenStart.upperBound..<settingsSource.endIndex))
        let settingsOpenBody = settingsSource[settingsOpenStart.lowerBound..<settingsOpenEnd.lowerBound]
        #expect(settingsOpenBody.contains("scannerResultHandoff.beginScan()"))
        #expect(settingsOpenBody.contains("showQRScanner = true"))
        #expect(!settingsOpenBody.contains("disconnectGateway()"))

        let settingsReplacementEnd = try #require(
            settingsSource.range(of: "func queueScannedResult", range: settingsOpenEnd.upperBound..<settingsSource.endIndex))
        let settingsReplacementBody = settingsSource[settingsOpenEnd.lowerBound..<settingsReplacementEnd.lowerBound]
        #expect(settingsReplacementBody.contains("connectAfterScannedGatewayLink"))

        let settingsInvalidateStart = try #require(settingsSource.range(of: "func invalidateGatewaySetupAttempt()"))
        let settingsInvalidateEnd = try #require(
            settingsSource.range(of: "func connectManual", range: settingsInvalidateStart.upperBound..<settingsSource.endIndex))
        #expect(!settingsSource[settingsInvalidateStart.lowerBound..<settingsInvalidateEnd.lowerBound]
            .contains("disconnectGateway()"))

        let onboardingSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Onboarding/OnboardingWizardView.swift"),
            encoding: .utf8)
        let gatewayOnboardingSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Onboarding/GatewayOnboardingView.swift"),
            encoding: .utf8)
        let onboardingOpenStart = try #require(onboardingSource.range(of: "private func openQRScannerFromOnboarding()"))
        let onboardingOpenEnd = try #require(
            onboardingSource.range(
                of: "private func applyPendingGatewaySetupLinkIfNeeded",
                range: onboardingOpenStart.upperBound..<onboardingSource.endIndex))
        let onboardingOpenBody = onboardingSource[onboardingOpenStart.lowerBound..<onboardingOpenEnd.lowerBound]
        #expect(onboardingOpenBody.contains("scannerResultHandoff.beginScan()"))
        #expect(onboardingOpenBody.contains("showQRScanner = true"))
        #expect(!onboardingOpenBody.contains("disconnectGateway()"))

        let onboardingInvalidateStart = try #require(
            onboardingSource.range(of: "private func invalidateGatewaySetupAttempt()"))
        let onboardingInvalidateEnd = try #require(
            onboardingSource.range(
                of: "private func resumeAfterPairingApproval",
                range: onboardingInvalidateStart.upperBound..<onboardingSource.endIndex))
        #expect(!onboardingSource[onboardingInvalidateStart.lowerBound..<onboardingInvalidateEnd.lowerBound]
            .contains("disconnectGateway()"))
        let onboardingInvalidateBody =
            onboardingSource[onboardingInvalidateStart.lowerBound..<onboardingInvalidateEnd.lowerBound]
        #expect(onboardingInvalidateBody.contains("self.pendingManualAuthOverride = nil"))
        #expect(onboardingInvalidateBody.contains("self.stagedGatewaySetupLink = nil"))

        let onboardingBeginStart = try #require(
            onboardingSource.range(of: "private func beginGatewaySetupAttempt()"))
        let onboardingBeginEnd = try #require(
            onboardingSource.range(
                of: "private func invalidateGatewaySetupAttempt()",
                range: onboardingBeginStart.upperBound..<onboardingSource.endIndex))
        #expect(onboardingSource[onboardingBeginStart.lowerBound..<onboardingBeginEnd.lowerBound]
            .contains("self.pendingManualAuthOverride = nil"))

        #expect(gatewayOnboardingSource.contains("self.pendingManualAuthOverride = nil"))

        // Bootstrap credentials and outbox reset remain staged until the
        // controller has persisted an accepted TLS fingerprint.
        #expect(!settingsSource.contains("GatewayOnboardingReset.prepareForBootstrapPairing"))
        #expect(!onboardingSource.contains("GatewayOnboardingReset.prepareForBootstrapPairing"))
        #expect(settingsSource.contains("if setupAuth.hasBootstrapToken"))
        #expect(settingsSource.contains("self.pendingManualSetupLink = link"))
        #expect(settingsSource.contains("let pendingLink = self.pendingManualSetupLink"))
        #expect(gatewayOnboardingSource.contains("let isBootstrapSetup ="))
        #expect(gatewayOnboardingSource.contains("if !isBootstrapSetup"))

        let controllerSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Gateway/GatewayConnectionController.swift"),
            encoding: .utf8)
        let acceptStart = try #require(controllerSource.range(of: "func acceptPendingTrustPrompt"))
        let acceptEnd = try #require(
            controllerSource.range(
                of: "func declinePendingTrustPrompt",
                range: acceptStart.upperBound..<controllerSource.endIndex))
        let acceptBody = controllerSource[acceptStart.lowerBound..<acceptEnd.lowerBound]
        let persist = try #require(acceptBody.range(of: "persistTLSFingerprint"))
        let prepare = try #require(acceptBody.range(of: "prepareBootstrapReplacementIfNeeded"))
        let applyConfig = try #require(acceptBody.range(of: "await self.applyAutoConnectConfig"))
        #expect(persist.lowerBound < prepare.lowerBound)
        #expect(prepare.lowerBound < applyConfig.lowerBound)
        #expect(controllerSource.contains("if pendingOverride.bootstrapToken?.isEmpty == false"))
        #expect(controllerSource.contains("return pendingOverride"))
        #expect(controllerSource.contains("self.ownsConnectionAdmission(admissionGeneration)"))

        let resetSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Onboarding/GatewayOnboardingReset.swift"),
            encoding: .utf8)
        #expect(resetSource.contains("prepareForTrustedBootstrapPairing"))
        #expect(resetSource.contains("clearTLSFingerprints: false"))
    }

    @Test func queuedResultIsDeliveredOnceAfterDismissal() async throws {
        let handoff = QRScannerResultHandoff(settlingNanoseconds: 0)
        var deliveredResult: QRScannerResult?

        let scanID = handoff.beginScan()
        handoff.queue(.setupCode("review-demo"), scanID: scanID)
        let task = try #require(handoff.processAfterDismissal { deliveredResult = $0 })
        await task.value

        #expect(deliveredResult == .setupCode("review-demo"))
        #expect(handoff.processAfterDismissal { _ in } == nil)
    }

    @Test func cancelPreventsQueuedDelivery() async throws {
        let handoff = QRScannerResultHandoff(settlingNanoseconds: 1_000_000_000)
        var deliveredResult: QRScannerResult?

        let scanID = handoff.beginScan()
        handoff.queue(.setupCode("review-demo"), scanID: scanID)
        let task = try #require(handoff.processAfterDismissal { deliveredResult = $0 })
        handoff.cancel()
        await task.value

        #expect(deliveredResult == nil)
    }

    @Test func beginningAnotherScanClearsStaleResult() {
        let handoff = QRScannerResultHandoff(settlingNanoseconds: 0)

        let staleScanID = handoff.beginScan()
        handoff.queue(.setupCode("stale"), scanID: staleScanID)
        handoff.beginScan()

        #expect(handoff.processAfterDismissal { _ in } == nil)
    }

    @Test func lateResultFromCancelledScanCannotReplaceNewerInput() async throws {
        let handoff = QRScannerResultHandoff(settlingNanoseconds: 0)
        let staleScanID = handoff.beginScan()
        handoff.cancel()
        let currentScanID = handoff.beginScan()
        var deliveredResult: QRScannerResult?

        #expect(!handoff.queue(.setupCode("stale"), scanID: staleScanID))
        #expect(handoff.queue(.setupCode("current"), scanID: currentScanID))
        let task = try #require(handoff.processAfterDismissal { deliveredResult = $0 })
        await task.value

        #expect(deliveredResult == .setupCode("current"))
    }

    @Test func firstProducerClaimsTheActiveScan() async throws {
        let handoff = QRScannerResultHandoff(settlingNanoseconds: 0)
        let scanID = handoff.beginScan()
        var deliveredResult: QRScannerResult?

        #expect(handoff.queue(.setupCode("camera"), scanID: scanID))
        #expect(!handoff.isActive(scanID: scanID))
        #expect(!handoff.queue(.setupCode("photo"), scanID: scanID))
        let task = try #require(handoff.processAfterDismissal { deliveredResult = $0 })
        await task.value

        #expect(deliveredResult == .setupCode("camera"))
    }
}
