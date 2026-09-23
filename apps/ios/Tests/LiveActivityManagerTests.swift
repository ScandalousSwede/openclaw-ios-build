import Foundation
import Testing
@testable import OpenClaw

@Suite(.serialized) struct LiveActivityManagerTests {
    private static let taskID = "d6b7479f-8a75-4d6b-88d9-377c4bdcc823"

    private static func taskSnapshot(
        _ update: (inout [String: Any]) -> Void = { _ in }) throws -> ArgusTaskActivitySnapshot
    {
        var value: [String: Any] = [
            "taskId": Self.taskID, "invocationRequestId": "synthetic-invocation",
            "lifecycleRevision": 2, "activityExpiresAt": 2000000,
            "status": "succeeded", "terminalOutcome": "blocked", "phase": "blocked",
            "deliveryStatus": "pending",
        ]
        update(&value)
        return try JSONDecoder().decode(
            ArgusTaskActivitySnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @Test func blockedOutcomeAndPendingDeliveryDoNotBecomeCompletion() throws {
        let blocked = try Self.taskSnapshot()
        try blocked.validate(taskID: Self.taskID, requestID: "synthetic-invocation")
        #expect(blocked.phase.headline == "Task blocked")
        #expect(blocked.status == .succeeded && blocked.deliveryStatus == .pending)
        #expect(!blocked.canStartActivity(at: .distantPast))
        let misleading = try Self.taskSnapshot { $0["phase"] = "succeeded" }
        #expect(throws: ArgusOperationsError.self) { try misleading.validate(taskID: Self.taskID) }
        let invalidRevision = try Self.taskSnapshot { $0["lifecycleRevision"] = 0 }
        #expect(throws: ArgusOperationsError.self) { try invalidRevision.validate(taskID: Self.taskID) }
        let contradictory = try Self.taskSnapshot { $0["status"] = "running" }
        #expect(throws: ArgusOperationsError.self) { try contradictory.validate(taskID: Self.taskID) }
        let failedWithRetainedOutcome = try Self.taskSnapshot {
            $0["status"] = "failed"
            $0["phase"] = "failed"
        }
        try failedWithRetainedOutcome.validate(taskID: Self.taskID)
        #expect(failedWithRetainedOutcome.phase == .failed)
        let wrongOverride = try Self.taskSnapshot { $0["status"] = "failed" }
        #expect(throws: ArgusOperationsError.self) { try wrongOverride.validate(taskID: Self.taskID) }
    }

    @Test func taskRevisionRejectsRollbackAndConflictingEqualRevision() throws {
        let first = try Self.taskSnapshot()
        try first.validateSuccessor(of: first)
        let old = try Self.taskSnapshot { $0["lifecycleRevision"] = 1 }
        #expect(throws: ArgusOperationsError.self) { try old.validateSuccessor(of: first) }
        let conflicting = try Self.taskSnapshot { $0["deliveryStatus"] = "delivered" }
        #expect(throws: ArgusOperationsError.self) { try conflicting.validateSuccessor(of: first) }
        let newer = try Self.taskSnapshot {
            $0["lifecycleRevision"] = 3
            $0["deliveryStatus"] = "delivered"
        }
        try newer.validateSuccessor(of: first)
        let renewed = try Self.taskSnapshot {
            $0["lifecycleRevision"] = 3
            $0["activityExpiresAt"] = 2000001
        }
        #expect(throws: ArgusOperationsError.self) { try renewed.validateSuccessor(of: first) }
    }

    @Test @MainActor func exactTaskReadVerifiesGatewayAndInvocationAndPermitsExpiredContext() async throws {
        let reference = try #require(ArgusTaskActivityReference(
            gatewayDeviceID: "synthetic-gateway", taskID: Self.taskID, requestID: "synthetic-invocation"))
        let snapshot = try Self.taskSnapshot {
            $0.removeValue(forKey: "terminalOutcome")
            $0["status"] = "running"
            $0["phase"] = "running"
        }
        var reads = 0
        do {
            _ = try await reference.resolve(
                identity: { .init(deviceId: "another-gateway") },
                task: { _ in reads += 1; return .init(task: snapshot) }, stillCurrent: { true })
            Issue.record("Foreign gateway unexpectedly resolved")
        } catch {}
        #expect(reads == 0)
        let exact = try await reference.resolve(
            identity: { .init(deviceId: "synthetic-gateway") },
            task: { params in
                #expect(params == ["taskId": Self.taskID, "invocationRequestId": "synthetic-invocation"])
                return .init(task: snapshot)
            }, stillCurrent: { true })
        #expect(exact == snapshot)
        #expect(!exact.canStartActivity(at: Date(timeIntervalSince1970: 2001)))
        for retireAtIdentity in [true, false] {
            var current = true
            do {
                _ = try await reference.resolve(
                    identity: {
                        if retireAtIdentity { current = false }
                        return .init(deviceId: "synthetic-gateway")
                    }, task: { _ in current = false; return .init(task: snapshot) }, stillCurrent: { current })
                Issue.record("Retired task read unexpectedly resolved")
            } catch {}
        }
        let otherInvocation = try Self.taskSnapshot { $0["invocationRequestId"] = "another-invocation" }
        do {
            _ = try await reference.resolve(
                identity: { .init(deviceId: "synthetic-gateway") },
                task: { _ in .init(task: otherInvocation) }, stillCurrent: { true })
            Issue.record("Another invocation unexpectedly resolved")
        } catch {}
    }

    @Test @MainActor func taskAndEvidenceNavigationRetainSeparateReopenReferences() throws {
        let model = NodeAppModel()
        let evidence = ArgusEvidenceNotificationReference(
            gatewayDeviceId: "synthetic-gateway", operationId: "synthetic-operation",
            eventId: "synthetic-event", artifactSha256: nil)
        model.openArgusEvidenceNotification(evidence)
        let reference = try #require(ArgusTaskActivityReference(
            gatewayDeviceID: "synthetic-gateway", taskID: Self.taskID, requestID: "synthetic-invocation"))
        #expect(model.handleTaskActivityURL(try #require(reference.url)))
        #expect(model.argusEvidenceNotificationRequest == nil)
        #expect(model.lastArgusEvidenceNotificationRequest?.reference == evidence)
        model.reopenLastArgusEvidenceNotification()
        #expect(model.argusTaskActivityRequest == nil)
        #expect(model.lastArgusTaskActivityRequest?.reference == reference)
        model.reopenLastTaskActivity()
        #expect(model.argusEvidenceNotificationRequest == nil)
        #expect(model.argusTaskActivityRequest?.reference == reference)
    }

    @Test @MainActor func taskActivityOpenBackReopenRetainsOwnerWithoutSubmittingMessage() async throws {
        let model = NodeAppModel()
        model._test_setChatOutboxGatewayOwnerID("synthetic-owner")
        let reference = try #require(ArgusTaskActivityReference(
            gatewayDeviceID: "synthetic-gateway", taskID: Self.taskID, requestID: "synthetic-request"))
        let url = try #require(reference.url)
        let chatRequest = model.openChatRequestID
        await model.handleDeepLink(url: url)
        let original = try #require(model.argusTaskActivityRequest)
        #expect(original.reference == reference)
        #expect(original.gatewayOwnerID == "synthetic-owner")
        #expect(model.openChatRequestID == chatRequest)
        #expect(model.pendingAgentDeepLinkPrompt == nil)

        model.argusTaskActivityRequest = nil
        model._test_setChatOutboxGatewayOwnerID("different-owner")
        model.reopenLastTaskActivity()
        #expect(model.argusTaskActivityRequest == original)
        #expect(model.argusTaskActivityPresentationID == 2)
        #expect(model.argusTaskActivityRequest?.gatewayOwnerID != model.chatOutboxGatewayOwnerID)

        let next = try #require(ArgusTaskActivityReference(
            gatewayDeviceID: "different-gateway", taskID: Self.taskID, requestID: "next-request"))
        #expect(model.handleTaskActivityURL(try #require(next.url)))
        #expect(model.argusTaskActivityRequest?.reference == next)
        #expect(model.lastArgusTaskActivityRequest?.reference == next)
        #expect(model.argusTaskActivityPresentationID == 3)
        #expect(model.openChatRequestID == chatRequest && model.pendingAgentDeepLinkPrompt == nil)
    }

    @Test @MainActor func warmActivityTapPreservesOriginalTitleAndGatewayThroughBackAndOwnerSwitch() throws {
        let model = NodeAppModel()
        model._test_setChatOutboxGatewayOwnerID("original-owner")
        let reference = try #require(ArgusTaskActivityReference(
            gatewayDeviceID: "synthetic-gateway", taskID: Self.taskID, requestID: "synthetic-invocation"))
        let original = ArgusTaskActivityRequest(
            reference: reference, gatewayOwnerID: "original-owner", title: "Synthetic administrative task")
        model.openTaskActivity(original)
        let url = try #require(reference.url)
        #expect(model.handleTaskActivityURL(url))
        #expect(model.argusTaskActivityRequest == original)
        model.argusTaskActivityRequest = nil
        model._test_setChatOutboxGatewayOwnerID("different-owner")
        #expect(model.handleTaskActivityURL(url))
        #expect(model.argusTaskActivityRequest == original)
        #expect(model.lastArgusTaskActivityRequest == original)
        model.argusTaskActivityRequest = nil
        model._test_setChatOutboxGatewayOwnerID("original-owner")
        model.reopenLastTaskActivity()
        #expect(model.argusTaskActivityRequest == original)
        #expect(model.pendingAgentDeepLinkPrompt == nil)
    }

    @Test func taskActivityURLPreservesExactOpaqueIdentityWithoutMessageActions() throws {
        let reference = try #require(ArgusTaskActivityReference(
            gatewayDeviceID: "synthetic-gateway", taskID: Self.taskID,
            requestID: "Synthetic-request_1.2:3"))
        let url = try #require(reference.url)
        #expect(ArgusTaskActivityReference.parse(url) == reference)
        #expect(try JSONDecoder().decode(
            ArgusTaskActivityReference.self, from: JSONEncoder().encode(reference)) == reference)
        for raw in [
            "openclaw://agent?gateway=g&task=\(Self.taskID)&request=r",
            "https://task?gateway=g&task=\(Self.taskID)&request=r",
            "openclaw://task?gateway=g&task=\(Self.taskID)&request=r&message=send",
            "openclaw://task?gateway=g&task=\(Self.taskID)&task=\(Self.taskID)",
            "openclaw://task?gateway=g&task=\(Self.taskID)&request=",
            "openclaw://task?gateway=g&task=\(Self.taskID)&request=%0Asecret",
            "openclaw://task/path?gateway=g&task=\(Self.taskID)&request=r",
            "openclaw://task?gateway=g&task=\(Self.taskID)&request=r#fragment",
            "openclaw://user@task?gateway=g&task=\(Self.taskID)&request=r",
        ] {
            #expect(ArgusTaskActivityReference.parse(try #require(URL(string: raw))) == nil)
        }
    }

    @Test func earlierSessionActivityAttributesRemainDecodableWithoutTaskReference() throws {
        let old = Data(#"{"agentName":"synthetic-agent","sessionKey":"synthetic-session"}"#.utf8)
        let attributes = try JSONDecoder().decode(OpenClawActivityAttributes.self, from: old)
        #expect(attributes.taskReference == nil)
        #expect(attributes.agentName == "synthetic-agent")
        let invalid = Data(#"{"gatewayDeviceID":"g","taskID":"t","requestID":" "}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ArgusTaskActivityReference.self, from: invalid)
        }
    }

    @Test func taskReferenceAndSnapshotEnforceTheSameBackendIdentityAndIntegerBounds() throws {
        let maximum = String(repeating: "A", count: 256)
        let accepted = try #require(ArgusTaskActivityReference(
            gatewayDeviceID: "synthetic-gateway", taskID: Self.taskID, requestID: maximum))
        #expect(ArgusTaskActivityReference.parse(try #require(accepted.url)) == accepted)
        #expect(ArgusTaskActivityReference(
            gatewayDeviceID: "synthetic-gateway", taskID: Self.taskID.uppercased(), requestID: "request") == nil)
        for requestID in ["", "_request", "-request", "request=1", "request/1", "request 1", "réquest", maximum + "A"] {
            #expect(ArgusTaskActivityReference(
                gatewayDeviceID: "synthetic-gateway", taskID: Self.taskID, requestID: requestID) == nil)
            let snapshot = try Self.taskSnapshot { $0["invocationRequestId"] = requestID }
            #expect(throws: ArgusOperationsError.self) { try snapshot.validate(taskID: Self.taskID) }
        }
        let exact = try Self.taskSnapshot {
            $0["invocationRequestId"] = "Request:1"
            $0["activityExpiresAt"] = Int64(9_007_199_254_740_991)
            $0["lifecycleRevision"] = Int64(9_007_199_254_740_991)
        }
        try exact.validate(taskID: Self.taskID, requestID: "Request:1")
        #expect(throws: ArgusOperationsError.self) {
            try exact.validate(taskID: Self.taskID, requestID: "request:1")
        }
        for field in ["activityExpiresAt", "lifecycleRevision"] {
            let unsafe = try Self.taskSnapshot { $0[field] = Int64(9_007_199_254_740_992) }
            #expect(throws: ArgusOperationsError.self) { try unsafe.validate(taskID: Self.taskID) }
        }
    }

    @Test @MainActor func featureFlagSupportsRuntimeAndBuildEnvironmentDisable() {
        let suiteName = "LiveActivityManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #if OPENCLAW_DISABLE_LIVE_ACTIVITY
        #expect(!LiveActivityFeatureFlag.isEnabled(defaults: defaults, environment: [:]))
        #else
        #expect(LiveActivityFeatureFlag.isEnabled(defaults: defaults, environment: [:]))
        LiveActivityFeatureFlag.setRuntimeEnabled(false, defaults: defaults)
        #expect(!LiveActivityFeatureFlag.isEnabled(defaults: defaults, environment: [:]))
        LiveActivityFeatureFlag.setRuntimeEnabled(true, defaults: defaults)
        #expect(LiveActivityFeatureFlag.isEnabled(defaults: defaults, environment: [:]))
        #expect(!LiveActivityFeatureFlag.isEnabled(
            defaults: defaults,
            environment: [LiveActivityFeatureFlag.disabledEnvironmentKey: "true"]))
        #expect(LiveActivityFeatureFlag.isHardDisabled(
            environment: [LiveActivityFeatureFlag.disabledEnvironmentKey: "true"]))
        #expect(!LiveActivityFeatureFlag.isHardDisabled(environment: [:]))
        #endif
    }

    @Test @MainActor func discoveryUsesActualTaskIDAndPinsReturnedInvocationWithoutInventingOne() async throws {
        let snapshot = try Self.taskSnapshot()
        let reference = try await ArgusTaskActivityReference.discover(
            taskID: Self.taskID, identity: { .init(deviceId: "synthetic-gateway") },
            task: { params in
                #expect(params == ["taskId": Self.taskID])
                return .init(task: snapshot)
            }, stillCurrent: { true })
        #expect(reference.taskID == Self.taskID && reference.requestID == "synthetic-invocation")
        let other = try Self.taskSnapshot { $0["taskId"] = UUID().uuidString.lowercased() }
        do {
            _ = try await ArgusTaskActivityReference.discover(
                taskID: Self.taskID, identity: { .init(deviceId: "synthetic-gateway") },
                task: { _ in .init(task: other) }, stillCurrent: { true })
            Issue.record("Discovery returned a different task")
        } catch {}
        var current = true
        do {
            _ = try await ArgusTaskActivityReference.discover(
                taskID: Self.taskID, identity: { current = false; return .init(deviceId: "synthetic-gateway") },
                task: { _ in Issue.record("Retired discovery made a task request"); return .init(task: snapshot) },
                stillCurrent: { current })
            Issue.record("Retired discovery returned context")
        } catch {}
    }

    @Test @MainActor func taskListingKeepsUsefulRowsAndRejectsLateOwnerAndSelectionReturns() async throws {
        let store = ArgusTaskActivityListStore()
        let item = ArgusTaskActivityList.Item(
            taskId: Self.taskID, title: "Synthetic administrative task", status: .completed, updatedAt: 2000)
        let page = ArgusTaskActivityList(tasks: [item], nextCursor: "1")
        store.selectGateway("owner-a")
        await store.refresh(gatewayID: "owner-a") { params in
            #expect(params.isEmpty)
            return page
        }
        #expect(store.items == [item] && !store.unavailable)
        #expect(item.status.label == "Execution ended; outcome not checked")
        await store.refresh(gatewayID: "owner-a", more: true) { params in
            #expect(params == ["cursor": "1"])
            return .init(tasks: [item], nextCursor: "1")
        }
        #expect(store.items == [item] && store.unavailable)
        await store.refresh(gatewayID: "owner-a") { _ in page }
        let reference = try #require(ArgusTaskActivityReference(
            gatewayDeviceID: "synthetic-gateway", taskID: Self.taskID, requestID: "synthetic-invocation"))
        let selected = await store.select(item, gatewayID: "owner-a") { reference }
        #expect(selected?.title == item.title && selected?.gatewayOwnerID == "owner-a")
        let retired = await store.select(item, gatewayID: "owner-a") {
            store.selectGateway("owner-b")
            return reference
        }
        #expect(retired == nil && store.items.isEmpty && store.selectionID == nil)
        await store.refresh(gatewayID: "owner-b") { _ in
            store.markUnavailable()
            return page
        }
        #expect(store.items.isEmpty && store.unavailable)
        await store.refresh(gatewayID: "owner-b") { _ in page }
        let unbound = await store.select(item, gatewayID: "owner-b") { throw ArgusOperationsError.unavailable }
        #expect(unbound == nil && store.selectionError != nil && store.items == [item])
    }

    @Test func taskListingRejectsDuplicateIdentityAndNonAdvancingOrMalformedPages() throws {
        let item = ArgusTaskActivityList.Item(taskId: Self.taskID, title: "Synthetic task", status: .running, updatedAt: 0)
        for page in [
            ArgusTaskActivityList(tasks: [item, item], nextCursor: nil),
            ArgusTaskActivityList(tasks: [item], nextCursor: "not-a-cursor"),
            ArgusTaskActivityList(tasks: [], nextCursor: "2"),
            ArgusTaskActivityList(tasks: [item], nextCursor: "1"),
        ] {
            #expect(throws: ArgusOperationsError.self) { try page.validate(after: "1") }
        }
    }

    @Test @MainActor func taskActivitySurvivesConnectionChangesAndEndsWithBlockedOutcome() async throws {
        let driver = MockLiveActivityDriver()
        let manager = LiveActivityManager(driver: driver, featureEnabled: { true })
        let reference = try #require(ArgusTaskActivityReference(
            gatewayDeviceID: "synthetic-gateway", taskID: Self.taskID, requestID: "synthetic-invocation"))
        let expiry = Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
        let running = try Self.taskSnapshot {
            $0["activityExpiresAt"] = expiry
            $0["status"] = "running"; $0["phase"] = "running"
            $0.removeValue(forKey: "terminalOutcome")
        }
        try manager.trackTask(running, reference: reference)
        await manager.waitUntilIdleForTesting()
        let activity = try #require(driver.created.first)
        #expect(activity.taskReference == reference && manager.isTracking(reference))
        #expect(activity.state.statusText == "Task running" && activity.staleDate == running.expiresAt)
        manager.handleReconnect()
        manager.handleDisconnect()
        manager.handleConnecting()
        manager.showAttention(statusText: "private session text", agentName: "other", sessionKey: "other")
        for reason in ["background_idle", "operator_disconnected", "gateway_loop_stopped"] {
            manager.endActivity(reason: reason)
        }
        await manager.waitUntilIdleForTesting()
        #expect(activity.endCount == 0 && driver.created.count == 1)
        #expect(activity.state.statusText == "Task running")
        let blocked = try Self.taskSnapshot {
            $0["lifecycleRevision"] = 3; $0["activityExpiresAt"] = expiry
        }
        try manager.refreshTask(blocked, reference: reference)
        await manager.waitUntilIdleForTesting()
        #expect(activity.endCount == 1 && !manager.isTracking(reference))
        #expect(activity.state.task?.phase == .blocked && activity.state.statusText == "Task blocked")
        #expect(activity.state.task?.trackingEnded == true && !activity.state.isIdle)
        #expect(throws: ArgusOperationsError.self) { try manager.trackTask(running, reference: reference) }
    }

    @Test @MainActor func taskReplacementIsSerializedAndStoppedTaskCannotRestartFromARead() async throws {
        let driver = MockLiveActivityDriver()
        let manager = LiveActivityManager(driver: driver, featureEnabled: { true })
        let reference = try #require(ArgusTaskActivityReference(
            gatewayDeviceID: "synthetic-gateway", taskID: Self.taskID, requestID: "synthetic-invocation"))
        let expiry = Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
        let running = try Self.taskSnapshot {
            $0["activityExpiresAt"] = expiry; $0["status"] = "running"; $0["phase"] = "running"
            $0.removeValue(forKey: "terminalOutcome")
        }
        manager.showConnecting(agentName: "main", sessionKey: "main")
        await manager.waitUntilIdleForTesting()
        let original = try #require(driver.created.first)
        original.suspendNextEnd = true
        try manager.trackTask(running, reference: reference)
        while !original.endIsSuspended { await Task.yield() }
        manager.endActivity(reason: "manual_disconnect")
        original.resumeEnd()
        await manager.waitUntilIdleForTesting()
        #expect(driver.created.count == 1)
        try manager.trackTask(running, reference: reference)
        await manager.waitUntilIdleForTesting()
        let task = try #require(driver.created.last)
        manager.stopTracking(reference)
        await manager.waitUntilIdleForTesting()
        try manager.refreshTask(running, reference: reference)
        await manager.waitUntilIdleForTesting()
        #expect(driver.created.count == 2 && task.endCount == 1 && !manager.isTracking(reference))
        #expect(task.state.statusText == "Tracking ended" && task.state.task?.phase == .running)
        #expect(driver.maximumConcurrentOperations == 1)
    }

    @Test @MainActor func refreshCoalescingKeepsExplicitStartAndCannotReplaceANewerTaskSelection() async throws {
        let driver = MockLiveActivityDriver()
        let manager = LiveActivityManager(driver: driver, featureEnabled: { true })
        let reference = try #require(ArgusTaskActivityReference(
            gatewayDeviceID: "synthetic-gateway", taskID: Self.taskID, requestID: "synthetic-invocation"))
        let expiry = Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
        let running = try Self.taskSnapshot {
            $0["activityExpiresAt"] = expiry
            $0["status"] = "running"
            $0["phase"] = "running"
            $0.removeValue(forKey: "terminalOutcome")
        }
        try manager.trackTask(running, reference: reference)
        try manager.refreshTask(running, reference: reference)
        await manager.waitUntilIdleForTesting()
        #expect(driver.created.count == 1 && manager.isTracking(reference))

        let nextID = UUID().uuidString.lowercased()
        let nextReference = try #require(ArgusTaskActivityReference(
            gatewayDeviceID: "synthetic-gateway", taskID: nextID, requestID: "another-invocation"))
        let next = try Self.taskSnapshot {
            $0["taskId"] = nextID
            $0["invocationRequestId"] = "another-invocation"
            $0["activityExpiresAt"] = expiry
            $0["status"] = "running"
            $0["phase"] = "running"
            $0.removeValue(forKey: "terminalOutcome")
        }
        try manager.trackTask(next, reference: nextReference)
        try manager.refreshTask(running, reference: reference)
        await manager.waitUntilIdleForTesting()
        #expect(driver.created.count == 2 && manager.isTracking(nextReference))
        manager.stopTracking(nextReference)
        await manager.waitUntilIdleForTesting()
    }

    @Test @MainActor func taskRefreshAndStopRemainEffectiveAcrossTheReplacementEndBarrier() async throws {
        for action in ["running", "succeeded", "stop"] {
            let driver = MockLiveActivityDriver()
            let manager = LiveActivityManager(driver: driver, featureEnabled: { true })
            let reference = try #require(ArgusTaskActivityReference(
                gatewayDeviceID: "synthetic-gateway", taskID: Self.taskID, requestID: "synthetic-invocation"))
            let expiry = Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
            let running = try Self.taskSnapshot {
                $0["activityExpiresAt"] = expiry
                $0["status"] = "running"; $0["phase"] = "running"
                $0.removeValue(forKey: "terminalOutcome")
            }
            manager.showConnecting(agentName: "main", sessionKey: "main")
            await manager.waitUntilIdleForTesting()
            let original = try #require(driver.created.first)
            original.suspendNextEnd = true
            try manager.trackTask(running, reference: reference)
            while !original.endIsSuspended { await Task.yield() }
            manager.handleReconnect()
            manager.showAttention(statusText: "session notice", agentName: "main", sessionKey: "main")
            let refreshed = try Self.taskSnapshot {
                $0["activityExpiresAt"] = expiry
                $0["lifecycleRevision"] = 3
                $0["status"] = action == "succeeded" ? "succeeded" : "running"
                $0["phase"] = action == "succeeded" ? "succeeded" : "running"
                $0.removeValue(forKey: "terminalOutcome")
            }
            if action == "stop" { manager.stopTracking(reference) }
            try manager.refreshTask(refreshed, reference: reference)
            original.resumeEnd()
            await manager.waitUntilIdleForTesting()
            if action == "running" {
                #expect(driver.created.count == 2 && manager.isTracking(reference))
                #expect(driver.created.last?.state.task?.lifecycleRevision == 3)
                manager.stopTracking(reference)
                await manager.waitUntilIdleForTesting()
            } else {
                #expect(driver.created.count == 1 && !manager.isTracking(reference))
            }
            #expect(driver.maximumConcurrentOperations == 1)
        }
    }

    @Test @MainActor func burstUsesOneWorkerAndEndsBeforeLatestReplacement() async throws {
        let driver = MockLiveActivityDriver()
        let manager = LiveActivityManager(driver: driver, featureEnabled: { true })

        manager.showConnecting(agentName: "main", sessionKey: "main")
        await manager.waitUntilIdleForTesting()
        let original = try #require(driver.created.first)

        original.suspendNextUpdate = true
        manager.showAttention(statusText: "first", agentName: "main", sessionKey: "main")
        while !original.updateIsSuspended { await Task.yield() }

        for index in 0..<300 {
            switch index % 3 {
            case 0:
                manager.endActivity(reason: "burst_\(index)")
            case 1:
                manager.showConnecting(
                    statusText: "connecting_\(index)",
                    agentName: "main",
                    sessionKey: "main")
            default:
                manager.showAttention(
                    statusText: "attention_\(index)",
                    agentName: "main",
                    sessionKey: "main")
            }
        }
        manager.showAttention(statusText: "final", agentName: "main", sessionKey: "main")
        original.resumeUpdate()
        await manager.waitUntilIdleForTesting()

        #expect(driver.maximumConcurrentOperations == 1)
        #expect(driver.created.count == 2)
        #expect(original.endCount == 1)
        #expect(original.isActive == false)
        let replacement = try #require(driver.created.last)
        #expect(replacement.state.statusText == "final")
        #expect(replacement.isActive)
        let originalEnd = try #require(driver.events.firstIndex(of: "end:\(original.id)"))
        let replacementStart = try #require(driver.events.firstIndex(of: "start:\(replacement.id)"))
        #expect(originalEnd < replacementStart)
    }

    @Test @MainActor func endInvalidatesSuspendedUpdateWithoutStartingReplacement() async throws {
        let driver = MockLiveActivityDriver()
        let manager = LiveActivityManager(driver: driver, featureEnabled: { true })

        manager.showConnecting(agentName: "main", sessionKey: "main")
        await manager.waitUntilIdleForTesting()
        let activity = try #require(driver.created.first)
        let admittedGeneration = manager.activityGeneration

        activity.suspendNextUpdate = true
        manager.showAttention(statusText: "approval", agentName: "main", sessionKey: "main")
        while !activity.updateIsSuspended { await Task.yield() }
        manager.endActivity(reason: "disconnect")
        #expect(manager.activityGeneration > admittedGeneration)
        activity.resumeUpdate()
        await manager.waitUntilIdleForTesting()

        #expect(driver.created.count == 1)
        #expect(activity.endCount == 1)
        #expect(!activity.isActive)
        #expect(!manager.isActive)
        #expect(driver.maximumConcurrentOperations == 1)
    }

    @Test @MainActor func cancelledWorkerRestartsToHonorQueuedEndBarrier() async throws {
        let driver = MockLiveActivityDriver()
        let manager = LiveActivityManager(driver: driver, featureEnabled: { true })

        manager.showConnecting(agentName: "main", sessionKey: "main")
        await manager.waitUntilIdleForTesting()
        let activity = try #require(driver.created.first)

        activity.suspendNextUpdate = true
        manager.showAttention(statusText: "approval", agentName: "main", sessionKey: "main")
        while !activity.updateIsSuspended { await Task.yield() }
        manager.cancelWorkerForTesting()
        manager.endActivity(reason: "cancelled_worker")
        activity.resumeUpdate()
        await manager.waitUntilIdleForTesting()

        #expect(driver.created.count == 1)
        #expect(activity.endCount == 1)
        #expect(!activity.isActive)
        #expect(!manager.isActive)
        #expect(driver.maximumConcurrentOperations == 1)
    }

    @Test @MainActor func contextReplacementEndsOldActivityBeforeStartingNewOwner() async throws {
        let driver = MockLiveActivityDriver()
        let manager = LiveActivityManager(driver: driver, featureEnabled: { true })

        manager.showConnecting(agentName: "main", sessionKey: "session-a")
        await manager.waitUntilIdleForTesting()
        let first = try #require(driver.created.first)

        first.suspendNextEnd = true
        manager.showConnecting(agentName: "main", sessionKey: "session-b")
        while !first.endIsSuspended { await Task.yield() }
        #expect(driver.created.count == 1)
        first.resumeEnd()
        await manager.waitUntilIdleForTesting()
        let second = try #require(driver.created.last)

        #expect(driver.created.count == 2)
        #expect(first.endCount == 1)
        #expect(second.sessionKey == "session-b")
        let firstEnd = try #require(driver.events.firstIndex(of: "end:\(first.id)"))
        let secondStart = try #require(driver.events.firstIndex(of: "start:\(second.id)"))
        #expect(firstEnd < secondStart)
    }

    @Test @MainActor func disablingDuringSuspendedUpdateEndsActiveActivity() async throws {
        let driver = MockLiveActivityDriver()
        var enabled = true
        let manager = LiveActivityManager(driver: driver, featureEnabled: { enabled })

        manager.showConnecting(agentName: "main", sessionKey: "main")
        await manager.waitUntilIdleForTesting()
        let activity = try #require(driver.created.first)

        activity.suspendNextUpdate = true
        manager.showAttention(statusText: "approval", agentName: "main", sessionKey: "main")
        while !activity.updateIsSuspended { await Task.yield() }
        enabled = false
        manager.refreshFeatureFlag()
        activity.resumeUpdate()
        await manager.waitUntilIdleForTesting()

        #expect(activity.endCount == 1)
        #expect(!activity.isActive)
        #expect(driver.created.count == 1)
        #expect(!manager.isActive)
    }

    @Test @MainActor func disabledFeatureEndsHydratedActivitiesAndRefusesNewOnes() async {
        let driver = MockLiveActivityDriver()
        let hydrated = driver.makeActivity(
            agentName: "main",
            sessionKey: "main",
            state: Self.connectingState("hydrated"),
            recordAsCreated: false)
        driver.initialActivities = [hydrated]
        let manager = LiveActivityManager(driver: driver, featureEnabled: { false })

        manager.showAttention(statusText: "ignored", agentName: "main", sessionKey: "main")
        await manager.waitUntilIdleForTesting()

        #expect(hydrated.endCount == 1)
        #expect(driver.created.isEmpty)
        #expect(!manager.isActive)
    }

    private static func connectingState(_ text: String) -> OpenClawActivityAttributes.ContentState {
        OpenClawActivityAttributes.ContentState(
            statusText: text,
            isIdle: false,
            isDisconnected: false,
            isConnecting: true,
            startedAt: .now)
    }
}

@MainActor
private final class MockLiveActivityDriver: LiveActivityDriving {
    var areActivitiesEnabled = true
    var initialActivities: [MockLiveActivityHandle] = []
    private(set) var created: [MockLiveActivityHandle] = []
    private(set) var events: [String] = []
    private(set) var maximumConcurrentOperations = 0
    private var concurrentOperations = 0

    func activities() -> [any LiveActivityHandle] {
        self.initialActivities
    }

    func request(
        attributes: OpenClawActivityAttributes,
        state: OpenClawActivityAttributes.ContentState,
        staleDate: Date?) throws -> any LiveActivityHandle
    {
        let handle = self.makeActivity(
            agentName: attributes.agentName,
            sessionKey: attributes.sessionKey,
            taskReference: attributes.taskReference,
            state: state,
            staleDate: staleDate,
            recordAsCreated: true)
        self.events.append("start:\(handle.id)")
        return handle
    }

    func makeActivity(
        agentName: String,
        sessionKey: String,
        taskReference: ArgusTaskActivityReference? = nil,
        state: OpenClawActivityAttributes.ContentState,
        staleDate: Date? = nil,
        recordAsCreated: Bool) -> MockLiveActivityHandle
    {
        let handle = MockLiveActivityHandle(
            id: "activity-\(self.created.count + self.initialActivities.count + 1)",
            agentName: agentName,
            sessionKey: sessionKey,
            taskReference: taskReference,
            state: state,
            staleDate: staleDate,
            driver: self)
        if recordAsCreated { self.created.append(handle) }
        return handle
    }

    func begin(_ event: String) {
        self.concurrentOperations += 1
        self.maximumConcurrentOperations = max(self.maximumConcurrentOperations, self.concurrentOperations)
        self.events.append(event)
    }

    func finish() {
        self.concurrentOperations -= 1
    }
}

@MainActor
private final class MockLiveActivityHandle: LiveActivityHandle {
    let id: String
    let agentName: String
    let sessionKey: String
    let taskReference: ArgusTaskActivityReference?
    private(set) var state: OpenClawActivityAttributes.ContentState
    private(set) var staleDate: Date?
    private(set) var isActive = true
    private(set) var endCount = 0
    var suspendNextUpdate = false
    private(set) var updateIsSuspended = false
    var suspendNextEnd = false
    private(set) var endIsSuspended = false

    private unowned let driver: MockLiveActivityDriver
    private var updateContinuation: CheckedContinuation<Void, Never>?
    private var endContinuation: CheckedContinuation<Void, Never>?

    init(
        id: String,
        agentName: String,
        sessionKey: String,
        taskReference: ArgusTaskActivityReference? = nil,
        state: OpenClawActivityAttributes.ContentState,
        staleDate: Date?,
        driver: MockLiveActivityDriver)
    {
        self.id = id
        self.agentName = agentName
        self.sessionKey = sessionKey
        self.taskReference = taskReference
        self.state = state
        self.staleDate = staleDate
        self.driver = driver
    }

    func update(state: OpenClawActivityAttributes.ContentState, staleDate: Date?) async {
        self.driver.begin("update:\(self.id):\(state.statusText)")
        defer { self.driver.finish() }
        if self.suspendNextUpdate {
            self.suspendNextUpdate = false
            self.updateIsSuspended = true
            await withCheckedContinuation { continuation in
                self.updateContinuation = continuation
            }
            self.updateIsSuspended = false
        }
        self.state = state
        self.staleDate = staleDate
    }

    func end(state: OpenClawActivityAttributes.ContentState) async {
        self.driver.begin("end:\(self.id)")
        defer { self.driver.finish() }
        if self.suspendNextEnd {
            self.suspendNextEnd = false
            self.endIsSuspended = true
            await withCheckedContinuation { continuation in
                self.endContinuation = continuation
            }
            self.endIsSuspended = false
        }
        self.state = state
        self.staleDate = nil
        self.isActive = false
        self.endCount += 1
    }

    func resumeUpdate() {
        self.updateContinuation?.resume()
        self.updateContinuation = nil
    }

    func resumeEnd() {
        self.endContinuation?.resume()
        self.endContinuation = nil
    }
}
