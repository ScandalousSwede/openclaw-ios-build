import SwiftUI

// Separate from the app's ordinary gateway exec prompts. No approval action is
// exposed while the broker's trusted-script admission is under correction.
struct ArgusAdminApprovalReadView: View {
    @Environment(NodeAppModel.self) private var appModel
    @State private var index: ArgusAdminApprovalIndex?
    @State private var reviewed: ArgusAdminApprovalReviewedDetail?
    @State private var status = "Checking admin requests…"
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProCard(radius: SettingsLayout.cardRadius) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Admin approvals", systemImage: "lock.shield")
                        .font(.headline)
                    Text("Review only. Elevated actions cannot be approved in the app yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(self.status)
                        .font(.subheadline.weight(.medium))
                    Button("Refresh requests", systemImage: "arrow.clockwise") {
                        Task { await self.refresh() }
                    }
                    .disabled(self.isLoading)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("argus.adminApprovals.refresh")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let index, !index.pending.isEmpty {
                ForEach(index.pending, id: \.requestId) { request in
                    ProCard(radius: SettingsLayout.cardRadius) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(request.reason)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(request.scriptPath)
                                .font(.subheadline.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Requested by \(request.requestedBy)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let issueURL = URL(string: "https://linear.app/argus-egillese/issue/\(request.issue)") {
                                Link("Open \(request.issue) in Linear", destination: issueURL)
                                    .font(.subheadline)
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier("argus.adminApprovals.issue")
                            }
                            Text("Expires \(request.expiresAt)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Read exact script", systemImage: "doc.text.magnifyingglass") {
                                Task { await self.open(request, in: index) }
                            }
                            .disabled(self.isLoading)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("argus.adminApprovals.readScript")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if let reviewed {
                ProCard(radius: SettingsLayout.cardRadius) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Changes since the previous approved version")
                            .font(.subheadline.weight(.semibold))
                        Text(reviewed.changes ?? "No previously approved version is recorded. Review the full script below.")
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("argus.adminApprovals.changes")
                        Text("Exact script for \(reviewed.request.issue)")
                            .font(.headline)
                        Text(reviewed.scriptText)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("argus.adminApprovals.exactScript")
                        Text("Arguments")
                            .font(.subheadline.weight(.semibold))
                        Text(reviewed.request.argsCanonical)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("argus.adminApprovals.arguments")
                        DisclosureGroup("Technical details") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Commit: \(reviewed.request.gitCommit)")
                                Text("Script SHA-256: \(reviewed.request.scriptSha256)")
                                Text("Arguments SHA-256: \(reviewed.request.argsSha256)")
                            }
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
        .task { await self.refresh() }
    }

    @MainActor private func client() -> ArgusAdminApprovalReadClient? {
        guard let gatewayID = self.appModel.chatOutboxGatewayOwnerID else { return nil }
        return .init(gateway: .init(session: self.appModel.operatorSession, gatewayID: gatewayID))
    }

    @MainActor private func refresh() async {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        self.index = nil
        self.reviewed = nil
        guard let client = self.client() else {
            self.status = "Admin requests unavailable. Connect the operator gateway and try again."
            return
        }
        do {
            let index = try await client.list()
            self.index = index
            self.status = index.pending.isEmpty
                ? "No pending admin requests at the last check."
                : "\(index.pending.count) pending admin \(index.pending.count == 1 ? "request" : "requests") at the last check."
        } catch {
            self.status = "Admin requests unavailable. Try again after the gateway reconnects."
        }
    }

    @MainActor private func open(_ request: ArgusAdminApprovalRequest,
                                 in index: ArgusAdminApprovalIndex) async {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        self.reviewed = nil
        guard let client = self.client() else {
            self.status = "The operator gateway disconnected. The script was not opened."
            return
        }
        do {
            self.reviewed = try await client.get(request, in: index)
            self.status = "Available script bytes match their recorded digests. Read-only review."
        } catch {
            self.status = "This request changed or its exact script could not be verified. Refresh before reviewing it."
        }
    }
}
