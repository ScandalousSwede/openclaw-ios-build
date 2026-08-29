import OpenClawKit
import SwiftUI

extension SettingsProTab {
    var settingsHeader: some View {
        Text("Settings")
            .font(.system(size: 28, weight: .bold))
            .padding(.horizontal, OpenClawProMetric.pagePadding)
            .padding(.top, 6)
    }

    var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Appearance", uppercase: false)
            ProCard(radius: SettingsLayout.cardRadius) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Appearance", selection: self.$appearancePreferenceRaw) {
                        ForEach(AppAppearancePreference.allCases) { preference in
                            Text(preference.label).tag(preference.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Follows iOS appearance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    var gatewaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Gateway", uppercase: false)
            ProCard(padding: 0, radius: SettingsLayout.cardRadius) {
                VStack(spacing: 0) {
                    NavigationLink(value: SettingsRoute.gateway) {
                        self.gatewayConnectionRow
                            .padding(14)
                            .frame(maxWidth: .infinity, minHeight: SettingsLayout.rowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                    self.gatewayDetailRow(label: "Address", value: self.gatewayAddress)
                    Divider()
                    self.gatewayDetailRow(label: "Server", value: self.gatewayServer)
                    Divider()
                    self.gatewayDetailRow(label: "Gateway/node", value: self.appModel.nodeRoleState.statusLabel)
                    Divider()
                    self.gatewayDetailRow(label: "Operator/chat", value: self.appModel.operatorRoleState.statusLabel)
                    Divider()
                    self.gatewayDetailRow(label: "Agents", value: self.appModel.gatewayAgentCountText)
                    Divider()
                    self.gatewayActions
                        .padding(14)
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    var gatewayConnectionRow: some View {
        HStack(spacing: 12) {
            ProIconBadge(
                systemName: "antenna.radiowaves.left.and.right",
                color: self.gatewayStatusColor)

            VStack(alignment: .leading, spacing: 3) {
                Text("Connection")
                    .font(.subheadline.weight(.semibold))
                Text(self.gatewayStatusDetail)
                    .font(.caption)
                    .foregroundStyle(self.gatewayStatusColor)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    func gatewayDetailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    var gatewayActions: some View {
        HStack(spacing: 10) {
            self.gatewayActionButton(
                title: "Reconnect",
                icon: "arrow.triangle.2.circlepath",
                color: OpenClawBrand.warn,
                isBusy: self.isReconnectingGateway,
                isDisabled: self.appModel.isAppleReviewDemoModeEnabled)
            {
                Task { await self.reconnectGateway() }
            }

            self.gatewayActionButton(
                title: "Diagnose",
                icon: "cross.case",
                color: Color(red: 0 / 255.0, green: 122 / 255.0, blue: 255 / 255.0),
                isBusy: self.isRefreshingGateway)
            {
                Task { await self.runDiagnostics() }
            }
        }
    }

    var settingsListSection: some View {
        VStack(spacing: 10) {
            self.settingsListRow(
                icon: "checkmark.shield.fill",
                title: "Approvals",
                detail: self.approvalsDetail,
                route: .approvals,
                color: self.pendingApproval == nil ? .secondary : OpenClawBrand.warn,
                badgeValue: self.pendingApproval == nil ? nil : "1")
            self.settingsListRow(
                icon: "person.2",
                title: "Permissions",
                detail: self.permissionsDetail,
                route: .permissions)
            self.settingsListRow(
                icon: "waveform",
                title: "Voice & Talk",
                detail: self.voiceDetail,
                route: .voice)
            self.settingsListRow(
                icon: "globe",
                title: "Diagnostics",
                detail: self.diagnosticsDetail,
                route: .diagnostics)
            self.settingsListRow(
                icon: "hand.raised",
                title: "Privacy",
                detail: self.privacyDetail,
                route: .privacy)
            self.settingsListRow(
                icon: "bell",
                title: "Notifications",
                detail: self.notificationStatusText,
                route: .notifications)
            self.settingsListRow(
                icon: "info.circle",
                title: "About",
                detail: DeviceInfoHelper.openClawVersionString(),
                route: .about)
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    func settingsListRow(
        icon: String,
        title: String,
        detail: String,
        route: SettingsRoute,
        color: Color = .secondary,
        badgeValue: String? = nil) -> some View
    {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                ProIconBadge(systemName: icon, color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let badgeValue {
                    ProValuePill(value: badgeValue, color: color)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: SettingsLayout.rowHeight, alignment: .leading)
            .proPanelSurface(radius: SettingsLayout.cardRadius)
        }
        .buttonStyle(.plain)
    }

    func destination(for route: SettingsRoute) -> some View {
        ZStack {
            OpenClawProBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch route {
                    case .gateway:
                        self.gatewayDestination
                    case .approvals:
                        self.approvalsDestination
                    case .permissions:
                        self.permissionsDestination
                    case .voice:
                        self.voiceDestination
                    case .diagnostics:
                        self.diagnosticsDestination
                    case .privacy:
                        self.privacyDestination
                    case .notifications:
                        self.notificationsDestination
                    case .about:
                        self.aboutDestination
                    }
                }
                .padding(.top, 18)
                .padding(.bottom, OpenClawProMetric.bottomScrollInset)
            }
        }
        .navigationTitle(self.title(for: route))
        .navigationBarTitleDisplayMode(.inline)
    }

    var gatewayDestination: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let gatewayProblem = self.appModel.lastGatewayProblem {
                self.gatewayProblemCard(gatewayProblem)
            }

            self.detailStatusCard(
                icon: "antenna.radiowaves.left.and.right",
                title: "Gateway",
                detail: self.gatewayStatusDetail,
                value: self.gatewayStatusValue,
                color: self.gatewayStatusColor)

            self.detailListCard {
                self.detailRow("Address", value: self.gatewayAddress)
                Divider()
                self.detailRow("Server", value: self.gatewayServer)
                Divider()
                self.detailRow("Discovered", value: "\(self.gatewayController.gateways.count)")
                Divider()
                self.detailRow("Default Agent", value: self.appModel.activeAgentName)
                Divider()
                self.detailRow("Gateway/node", value: self.appModel.nodeRoleState.statusLabel)
                Divider()
                self.detailRow("Operator/chat", value: self.appModel.operatorRoleState.statusLabel)
                Divider()
                self.detailRow("Agents", value: self.appModel.gatewayAgentCountText)
            }

            ProCard(radius: SettingsLayout.cardRadius) {
                self.gatewayActions
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)

            self.manualGatewayCard
            self.deviceIdentityCard
            self.agentSelectionCard
            self.gatewaySetupCard
            self.discoveredGatewaysCard
            self.gatewayAdvancedCard
        }
    }

    var approvalsDestination: some View {
        VStack(alignment: .leading, spacing: 14) {
            self.detailStatusCard(
                icon: "checkmark.shield.fill",
                title: "Approvals",
                detail: self.pendingApproval == nil ? "No gateway actions are waiting for review." :
                    "Review the pending gateway action.",
                value: self.pendingApproval == nil ? "clear" : "1 waiting",
                color: self.pendingApproval == nil ? OpenClawBrand.ok : OpenClawBrand.warn)

            self.approvalsReviewCard
        }
    }

    var approvalsReviewCard: some View {
        ProCard(radius: SettingsLayout.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                if let pendingApproval {
                    VStack(spacing: 0) {
                        ForEach(Array(self.approvalItems.enumerated()), id: \.element.id) { index, item in
                            SettingsApprovalRow(item: item)
                            if index < self.approvalItems.count - 1 {
                                Divider().padding(.leading, 46)
                            }
                        }
                    }

                    if let errorText = self.appModel.pendingExecApprovalPromptErrorText {
                        Text(errorText)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(OpenClawBrand.danger)
                    }

                    HStack(spacing: 8) {
                        Button {
                            Task { await self.appModel.resolvePendingExecApprovalPrompt(decision: "allow-once") }
                        } label: {
                            Label("Allow", systemImage: "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(self.appModel.pendingExecApprovalPromptResolving)

                        if pendingApproval.allowsAllowAlways {
                            Button {
                                Task {
                                    await self.appModel.resolvePendingExecApprovalPrompt(decision: "allow-always")
                                }
                            } label: {
                                Label("Always", systemImage: "checkmark.shield")
                            }
                            .buttonStyle(.bordered)
                            .disabled(self.appModel.pendingExecApprovalPromptResolving)
                        }

                        Button(role: .destructive) {
                            Task { await self.appModel.resolvePendingExecApprovalPrompt(decision: "deny") }
                        } label: {
                            Label("Deny", systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)
                        .disabled(self.appModel.pendingExecApprovalPromptResolving)

                        Spacer(minLength: 0)
                    }
                    .controlSize(.small)
                } else {
                    HStack(spacing: 12) {
                        ProIconBadge(systemName: "checkmark.shield.fill", color: OpenClawBrand.ok)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("No approvals waiting")
                                .font(.subheadline.weight(.semibold))
                            Text(self.approvalEmptyDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    var permissionsDestination: some View {
        VStack(alignment: .leading, spacing: 14) {
            self.toggleCard(
                icon: "camera",
                title: "Camera",
                detail: "Allow the gateway to request photos or video while OpenClaw is foregrounded.",
                isOn: self.$cameraEnabled)

            self.locationModeCard

            self.toggleCard(
                icon: "lock.display",
                title: "Keep Awake",
                detail: "Keep the screen awake while OpenClaw is open.",
                isOn: self.$preventSleep)

            self.privacyAccessCard
        }
    }

    var voiceDestination: some View {
        VStack(alignment: .leading, spacing: 14) {
            self.detailStatusCard(
                icon: "waveform",
                title: "Voice & Talk",
                detail: self.appModel.talkMode.gatewayTalkVoiceModeTitle,
                value: self.voiceDetail,
                color: self.talkEnabled || self.voiceWakeEnabled ? OpenClawBrand.accent : .secondary)

            self.voiceFeatureCard
            self.talkVoiceSettingsCard
            self.ttsDiagnosticCard
            self.shareSettingsCard
        }
    }

    var diagnosticsDestination: some View {
        VStack(alignment: .leading, spacing: 14) {
            self.detailStatusCard(
                icon: "checklist.checked",
                title: "Health Check",
                detail: "Run app, permission, and gateway-adjacent checks without editing setup.",
                value: self.diagnosticsHealthValue,
                color: self.gatewayDiagnosticConnected ? OpenClawBrand.ok : OpenClawBrand.warn)

            ProCard(radius: SettingsLayout.cardRadius) {
                self.gatewayActionButton(
                    title: "Run Diagnostics",
                    icon: "cross.case",
                    color: Color(red: 0 / 255.0, green: 122 / 255.0, blue: 255 / 255.0),
                    isBusy: self.isRefreshingGateway)
                {
                    Task { await self.runDiagnostics() }
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)

            self.diagnosticChecksCard

            self.detailListCard {
                self.detailRow("Device", value: DeviceInfoHelper.deviceFamily())
                Divider()
                self.detailRow("Platform", value: DeviceInfoHelper.platformStringForDisplay())
                Divider()
                self.detailRow("App", value: DeviceInfoHelper.openClawVersionString())
                Divider()
                self.detailRow("Model", value: DeviceInfoHelper.modelIdentifier())
            }

            self.crashDiagnosticExportCard
            self.ttsDiagnosticCard
            self.diagnosticsAdvancedCard
        }
    }

    var privacyDestination: some View {
        VStack(alignment: .leading, spacing: 14) {
            self.detailStatusCard(
                icon: "hand.raised",
                title: "Privacy",
                detail: "Control what device context OpenClaw can expose to the gateway.",
                value: self.privacyDetail,
                color: .secondary)

            self.toggleCard(
                icon: "camera",
                title: "Camera Access",
                detail: "Disable to block camera capture requests from the gateway.",
                isOn: self.$cameraEnabled)

            self.locationModeCard

            self.toggleCard(
                icon: "lock.open.display",
                title: "Background Listening",
                detail: "Allow active Talk sessions to continue while the app is backgrounded.",
                isOn: self.$talkBackgroundEnabled)

            self.privacyAccessCard
        }
    }

    var notificationsDestination: some View {
        VStack(alignment: .leading, spacing: 14) {
            self.detailStatusCard(
                icon: "bell",
                title: "Notifications",
                detail: "Approvals and event alerts from OpenClaw.",
                value: self.notificationStatusText,
                color: self.notificationStatusText == "Allowed" ? OpenClawBrand.ok : .secondary)

            ProCard(radius: SettingsLayout.cardRadius) {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        self.handleNotificationAction()
                    } label: {
                        Label(
                            self.notificationActionText,
                            systemImage: self.notificationStatusText == "Allowed" ? "gear" : "bell.badge")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Text("OpenClaw uses notifications for approval prompts and mirrored event alerts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)

            self.toggleCard(
                icon: "rectangle.stack.badge.play",
                title: "Live Activities",
                detail: "Show connection and attention state on the Lock Screen. " +
                    "Turning this off ends the current activity.",
                isOn: Binding(
                    get: { LiveActivityFeatureFlag.isEnabled() },
                    set: { enabled in
                        LiveActivityFeatureFlag.setRuntimeEnabled(enabled)
                        self.liveActivityDisabled = !enabled
                        LiveActivityManager.shared.refreshFeatureFlag()
                    }))
                .disabled(LiveActivityFeatureFlag.isHardDisabled())
        }
    }

    var aboutDestination: some View {
        VStack(alignment: .leading, spacing: 14) {
            self.detailStatusCard(
                icon: "info.circle",
                title: "OpenClaw",
                detail: "iOS companion app",
                value: DeviceInfoHelper.openClawVersionString(),
                color: OpenClawBrand.accent)

            self.detailListCard {
                self.detailRow("Version", value: DeviceInfoHelper.openClawVersionString())
                Divider()
                self.detailRow("Device", value: DeviceInfoHelper.deviceFamily())
                Divider()
                self.detailRow("Platform", value: DeviceInfoHelper.platformStringForDisplay())
                Divider()
                self.detailRow("Model", value: DeviceInfoHelper.modelIdentifier())
            }
        }
    }

    func gatewayActionButton(
        title: String,
        icon: String,
        color: Color,
        isBusy: Bool,
        isDisabled: Bool = false,
        action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: isBusy ? "hourglass" : icon)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .foregroundStyle(color)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(color.opacity(0.14))
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy || isDisabled)
    }

    func toggleCard(
        icon: String,
        title: String,
        detail: String,
        isOn: Binding<Bool>) -> some View
    {
        ProCard(radius: SettingsLayout.cardRadius) {
            Toggle(isOn: isOn) {
                HStack(spacing: 12) {
                    ProIconBadge(systemName: icon, color: isOn.wrappedValue ? OpenClawBrand.accent : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .toggleStyle(.switch)
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    var locationModeCard: some View {
        ProCard(radius: SettingsLayout.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ProIconBadge(
                        systemName: "location",
                        color: self.locationModeRaw == OpenClawLocationMode.off.rawValue ? .secondary : OpenClawBrand
                            .accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Location")
                            .font(.subheadline.weight(.semibold))
                        Text("Controls whether location can be shared with gateway tools.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if self.isChangingLocationMode {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Picker("Location", selection: self.$locationModeRaw) {
                    Text("Off").tag(OpenClawLocationMode.off.rawValue)
                    Text("While Using").tag(OpenClawLocationMode.whileUsing.rawValue)
                    Text("Always").tag(OpenClawLocationMode.always.rawValue)
                }
                .pickerStyle(.segmented)
                .disabled(self.isChangingLocationMode)

                if let locationStatusText {
                    Text(locationStatusText)
                        .font(.caption2)
                        .foregroundStyle(OpenClawBrand.warn)
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    var agentSelectionCard: some View {
        ProCard(radius: SettingsLayout.cardRadius) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Default Agent")
                    .font(.subheadline.weight(.semibold))
                Picker("Agent", selection: self.$selectedAgentPickerId) {
                    Text("Default").tag("")
                    let defaultId = (self.appModel.gatewayDefaultAgentId ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    ForEach(self.appModel.gatewayAgents.filter { $0.id != defaultId }, id: \.id) { agent in
                        let name = (agent.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        Text(name.isEmpty ? agent.id : name).tag(agent.id)
                    }
                }
                Text("Used for new Chat and Talk sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    var gatewaySetupCard: some View {
        ProCard(radius: SettingsLayout.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Setup Code")
                    .font(.subheadline.weight(.semibold))
                TextField("Paste setup code", text: self.$setupCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 10) {
                    self.gatewayActionButton(
                        title: "Scan QR",
                        icon: "qrcode.viewfinder",
                        color: OpenClawBrand.accent,
                        isBusy: self.connectingGatewayID != nil)
                    {
                        self.openGatewayQRScanner()
                    }
                    self.gatewayActionButton(
                        title: "Connect",
                        icon: "bolt.horizontal.circle",
                        color: OpenClawBrand.ok,
                        isBusy: self.connectingGatewayID == "manual")
                    {
                        Task { await self.applySetupCodeAndConnect() }
                    }
                    .disabled(!self.canApplyGatewaySetup)
                }
                if let status = self.setupStatusLine {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let warning = self.tailnetWarningText {
                    Text(warning)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(OpenClawBrand.warn)
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    var discoveredGatewaysCard: some View {
        ProCard(radius: SettingsLayout.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Discovered Gateways")
                    .font(.subheadline.weight(.semibold))
                if self.gatewayController.gateways.isEmpty {
                    Text("No gateways found yet. Use manual setup if Bonjour is blocked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(self.gatewayController.gateways) { gateway in
                        self.discoveredGatewayRow(gateway)
                        if gateway.id != self.gatewayController.gateways.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    func discoveredGatewayRow(_ gateway: GatewayDiscoveryModel.DiscoveredGateway) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: gateway.name)
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: self.gatewayDetailLines(gateway).joined(separator: " • "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button {
                Task { await self.connect(gateway) }
            } label: {
                if self.connectingGatewayID == gateway.id {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(.bordered)
            .disabled(self.connectingGatewayID != nil)
        }
    }

    var manualGatewayCard: some View {
        ProCard(radius: SettingsLayout.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                self.settingsButtonToggle("Use Manual Gateway", isOn: self.$manualGatewayEnabled)
                TextField("Host", text: self.$manualGatewayHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                TextField("Port", text: self.manualPortBinding)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                self.settingsButtonToggle("Use TLS", isOn: self.$manualGatewayTLS)
                self.gatewayActionButton(
                    title: "Connect Manual",
                    icon: "network",
                    color: OpenClawBrand.accent,
                    isBusy: self.connectingGatewayID == "manual")
                {
                    Task { await self.connectManual() }
                }
                .disabled(self.manualGatewayHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !self.manualPortIsValid)
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    var gatewayAdvancedCard: some View {
        ProCard(radius: SettingsLayout.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                self.settingsButtonToggle("Auto-connect on launch", isOn: self.$gatewayAutoConnect)
                SecureField("Gateway Auth Token", text: self.$gatewayToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                SecureField("Gateway Password", text: self.$gatewayPassword)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive) {
                    self.showResetOnboardingAlert = true
                } label: {
                    Label("Reset Onboarding", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    var voiceFeatureCard: some View {
        ProCard(radius: SettingsLayout.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                self.settingsToggle("Voice Wake", isOn: self.$voiceWakeEnabled) { enabled in
                    self.appModel.setVoiceWakeEnabled(enabled)
                }
                self.settingsToggle("Talk Mode", isOn: self.$talkEnabled) { enabled in
                    guard !self.appModel.isAppleReviewDemoModeEnabled else {
                        self.talkEnabled = false
                        return
                    }
                    self.appModel.setTalkEnabled(enabled)
                }
                .disabled(self.appModel.isAppleReviewDemoModeEnabled)
                Picker("Speech Language", selection: self.$talkSpeechLocale) {
                    ForEach(TalkSpeechLocale.supportedOptions()) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                self.settingsToggle("Background Listening", isOn: self.$talkBackgroundEnabled)
                self.settingsToggle("Speakerphone", isOn: self.talkSpeakerphoneBinding)
                NavigationLink {
                    VoiceWakeWordsSettingsView()
                } label: {
                    self.simpleSettingsRow(
                        title: "Wake Words",
                        value: VoiceWakePreferences.displayString(for: self.voiceWake.triggerWords))
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    var talkVoiceSettingsCard: some View {
        ProCard(radius: SettingsLayout.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Provider", selection: self.talkProviderSelectionBinding) {
                    ForEach(TalkModeProviderSelection.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                if self.shouldShowRealtimeVoicePicker {
                    Picker("Realtime Voice", selection: self.talkRealtimeVoiceSelectionBinding) {
                        Text("Gateway Default").tag("")
                        ForEach(TalkModeRealtimeVoiceSelection.voices, id: \.self) { voice in
                            Text(TalkModeRealtimeVoiceSelection.label(for: voice)).tag(voice)
                        }
                    }
                }
                self.detailRow("Voice Mode", value: self.appModel.talkMode.gatewayTalkVoiceModeTitle)
                Divider()
                self.detailRow("Transport", value: self.appModel.talkMode.gatewayTalkTransportLabel)
                Divider()
                self.detailRow("API Key", value: self.talkApiKeyStatus)
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    var ttsDiagnosticCard: some View {
        let diagnostics = self.appModel.talkMode.ttsDiagnostics
        let route = self.appModel.talkMode.currentAudioRouteEvidence
        return ProCard(radius: SettingsLayout.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Local Speech Diagnostics", systemImage: "speaker.wave.3.fill")
                    .font(.headline)
                Text(diagnostics.userMessage)
                    .font(.caption)
                    .foregroundStyle(diagnostics.state == .failed ? OpenClawBrand.danger : .secondary)

                HStack(spacing: 8) {
                    Button {
                        self.isTestingSystemVoice = true
                        Task {
                            await self.appModel.talkMode.testSystemVoice()
                            self.isTestingSystemVoice = false
                        }
                    } label: {
                        Label(
                            self.isTestingSystemVoice ? "Testing…" : "Test iOS Voice",
                            systemImage: "iphone.radiowaves.left.and.right")
                    }
                    .buttonStyle(.bordered)
                    .disabled(self.isTestingSystemVoice || self.isTestingElevenLabsVoice)

                    Button {
                        self.isTestingElevenLabsVoice = true
                        Task {
                            await self.appModel.talkMode.testElevenLabsVoice()
                            self.isTestingElevenLabsVoice = false
                        }
                    } label: {
                        Label(
                            self.isTestingElevenLabsVoice ? "Testing…" : "Test ElevenLabs Voice",
                            systemImage: "waveform.badge.mic")
                    }
                    .buttonStyle(.bordered)
                    .disabled(self.isTestingSystemVoice || self.isTestingElevenLabsVoice)
                }
                .controlSize(.small)

                if self.appModel.talkMode.hasPendingDurableMessage {
                    Divider()
                    Text("A recognized Talk message was not queued. Retry preserves its original command identity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            Task {
                                _ = await self.appModel.talkMode.retryPendingDurableMessage()
                            }
                        } label: {
                            Label("Retry Talk Message", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)

                        Button(role: .destructive) {
                            self.appModel.talkMode.discardPendingDurableMessage()
                        } label: {
                            Label("Discard", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                    .disabled(self.appModel.talkMode.isPersistingDurableMessage)
                }

                Divider()
                self.detailRow("TTS State", value: diagnostics.state.rawValue)
                Divider()
                self.detailRow("Config", value: diagnostics.config.loaded ? "Loaded" : "Not loaded")
                Divider()
                self.detailRow("Secret Scope", value: diagnostics.config.secretsAccess.rawValue)
                Divider()
                self.detailRow(
                    "operator.talk.secrets",
                    value: diagnostics.config.operatorTalkSecrets.rawValue)
                Divider()
                self.detailRow("Provider", value: diagnostics.config.provider)
                Divider()
                self.detailRow("Model", value: diagnostics.config.modelPresent ? "Present" : "Absent")
                Divider()
                self.detailRow("Voice ID", value: diagnostics.config.voiceIDPresent ? "Present" : "Absent")
                Divider()
                self.detailRow("API Key", value: diagnostics.config.apiKeyPresent ? "Present" : "Absent")
                Divider()
                self.detailRow("Credential Source", value: diagnostics.config.credentialSource.rawValue)
                Divider()
                self.detailRow("Credentials", value: diagnostics.config.credentialOwnership.rawValue)
                Divider()
                self.detailRow("Audio Output", value: route.outputSummary)
                Divider()
                self.detailRow("Audio Session", value: "\(route.category) • \(route.mode)")
                Divider()
                self.detailRow(
                    "OpenClaw Session",
                    value: "\(route.activation.rawValue) • speakerphone \(route.speakerphonePreferred ? "on" : "off")")
                Divider()
                self.detailRow("ElevenLabs Outcome", value: diagnostics.providerAttemptOutcome.rawValue)
                Divider()
                self.detailRow(
                    "Final Speech",
                    value: "\(diagnostics.finalProvider.rawValue) • \(diagnostics.finalOutcome.rawValue)")
                Divider()
                self.detailRow("Audio Bytes", value: "\(diagnostics.totalAudioBytes)")
                Divider()
                self.detailRow(
                    "PCM Rate",
                    value: diagnostics.pcmSampleRate.map { "\($0) Hz" } ?? "Not used")
                Divider()
                self.detailRow(
                    "Duration",
                    value: diagnostics.durationMilliseconds.map { "\($0) ms" } ?? "Not measured")
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    var shareSettingsCard: some View {
        ProCard(radius: SettingsLayout.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show Talk Control", isOn: self.$talkButtonEnabled)
                TextField("Default Share Instruction", text: self.$defaultShareInstruction, axis: .vertical)
                    .lineLimit(2...5)
                    .textInputAutocapitalization(.sentences)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await self.appModel.runSharePipelineSelfTest() }
                } label: {
                    Label("Run Share Self-Test", systemImage: "checkmark.seal")
                }
                .buttonStyle(.bordered)
                Text(self.appModel.lastShareEventText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    var privacyAccessCard: some View {
        ProCard(radius: SettingsLayout.cardRadius) {
            PrivacyAccessSectionView()
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    var diagnosticsAdvancedCard: some View {
        ProCard(radius: SettingsLayout.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                self.settingsButtonToggle("Discovery Debug Logs", isOn: self.$discoveryDebugLogsEnabled) { enabled in
                    self.gatewayController.setDiscoveryDebugLoggingEnabled(enabled)
                }
                self.settingsButtonToggle("Debug Screen Status", isOn: self.$canvasDebugStatusEnabled)
                NavigationLink {
                    GatewayDiscoveryDebugLogView()
                } label: {
                    self.simpleSettingsRow(title: "Discovery Logs", value: self.gatewayController.discoveryStatusText)
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    var crashDiagnosticExportCard: some View {
        ProCard(radius: SettingsLayout.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Crash Evidence", systemImage: "waveform.path.ecg.rectangle")
                    .font(.headline)
                Text(
                    "Prepare a bounded metadata-only export from the protected rolling log. "
                        + "Messages, prompts, tool payloads, credentials, and APNs tokens are excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    self.prepareCrashDiagnosticExport()
                } label: {
                    Label(
                        self.isPreparingCrashDiagnosticExport ? "Preparing…" : "Prepare Crash Export",
                        systemImage: "doc.badge.gearshape")
                }
                .buttonStyle(.bordered)
                .disabled(self.isPreparingCrashDiagnosticExport)

                if let crashDiagnosticExportURL {
                    ShareLink(item: crashDiagnosticExportURL) {
                        Label("Share Crash Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let crashDiagnosticExportStatus {
                    Text(crashDiagnosticExportStatus)
                        .font(.caption)
                        .foregroundStyle(crashDiagnosticExportURL == nil ? OpenClawBrand.warn : .secondary)
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    var deviceIdentityCard: some View {
        ProCard(radius: SettingsLayout.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Device Name", text: self.$displayName)
                    .textFieldStyle(.roundedBorder)
                self.detailRow("Instance ID", value: self.instanceId)
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    func gatewayProblemCard(_ problem: GatewayConnectionProblem) -> some View {
        ProCard(radius: SettingsLayout.cardRadius) {
            GatewayProblemBanner(
                problem: problem,
                primaryActionTitle: self.gatewayProblemPrimaryActionTitle(problem),
                onPrimaryAction: {
                    Task { await self.handleGatewayProblemPrimaryAction(problem) }
                },
                onShowDetails: {
                    self.showGatewayProblemDetails = true
                })
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    func settingsToggle(
        _ title: String,
        isOn: Binding<Bool>,
        onChange: ((Bool) -> Void)? = nil) -> some View
    {
        Toggle(title, isOn: isOn)
            .onChange(of: isOn.wrappedValue) { _, enabled in
                onChange?(enabled)
            }
    }

    func settingsButtonToggle(
        _ title: String,
        isOn: Binding<Bool>,
        onChange: ((Bool) -> Void)? = nil) -> some View
    {
        // Settings switch rows need full-width taps; wrapping Toggle crashes this NavigationStack on iOS 26.
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                self.settingsSwitchIndicator(isOn: isOn.wrappedValue)
            }
            .font(.subheadline)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .onChange(of: isOn.wrappedValue) { _, enabled in
            onChange?(enabled)
        }
    }

    func settingsSwitchIndicator(isOn: Bool) -> some View {
        Capsule()
            .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.35))
            .frame(width: 52, height: 32)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 28, height: 28)
                    .padding(2)
                    .shadow(color: Color.black.opacity(0.14), radius: 1, x: 0, y: 1)
            }
    }

    func simpleSettingsRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}
