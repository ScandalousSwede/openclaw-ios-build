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
