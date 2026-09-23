import ImageIO
import PDFKit
import SwiftUI

struct ArgusHomeResultContent: View {
    let store: ArgusOperationsStore
    let client: ArgusOperationsClient?
    var openWork: () -> Void

    var body: some View {
        CommandPanel(isProminent: true, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Latest report · \(self.store.project.rawValue)")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let item = self.store.items.first {
                    ArgusOperationRow(item: item)
                    if self.store.unavailable {
                        Label("Showing the last observation", systemImage: "wifi.slash")
                            .font(.subheadline)
                    }
                    if let client {
                        NavigationLink {
                            ArgusOperationDetailView(operation: item, client: client)
                        } label: {
                            Label(item.detailActionLabel, systemImage: "arrow.right")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if self.store.isLoading {
                    ProgressView("Loading your work")
                } else {
                    Text(self.store.unavailable ? "Connect to see your work and results." : "No results in this view yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button("All work and results", action: self.openWork)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }
}

struct ArgusOperationsContent: View {
    let store: ArgusOperationsStore
    let client: ArgusOperationsClient?

    var body: some View {
        CommandPanel(padding: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Project").font(.subheadline)
                    Picker("Project", selection: Binding(
                        get: { self.store.project }, set: { self.store.selectProject($0) }))
                    {
                        ForEach(ArgusEvidenceProject.allCases, id: \.self) { project in
                            Text(project.rawValue).tag(project)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Project")
                }
                Text("Report history").font(.headline).accessibilityAddTraits(.isHeader)
                Text("Current progress and requests aren't included in this history. Open a report for its recorded outcome and documents.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if self.store.project != .argus {
                    Text(
                        "Technical observations only. This view does not control equipment or establish scientific authority.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if self.store.unavailable {
                    Label(
                        self.store.items.isEmpty
                            ? "Reports unavailable. Connect and refresh."
                            : "Offline or unavailable — showing the last report list.",
                        systemImage: "wifi.slash")
                        .font(.subheadline)
                }
                if let observed = self.store.coverage?.observedAt {
                    Text("List checked: \(ArgusOperation.observationLabel(observed))").font(.caption)
                        .foregroundStyle(.secondary)
                }
                if self.store.items.isEmpty, !self.store.unavailable, !self.store.isLoading {
                    Text("No results found in this returned \(self.store.project.rawValue) view.")
                        .font(.subheadline)
                }
                self.records(self.store.items.filter { !$0.artifacts.isEmpty }, heading: "Reports with documents")
                self.records(self.store.items.filter { $0.artifacts.isEmpty }, heading: "Recorded updates")
                if self.store.isLoading {
                    ProgressView("Loading reports")
                }
                if let client {
                    HStack {
                        Button("Refresh") { Task { await self.store.refresh(using: client) } }
                        if self.store.nextCursor != nil {
                            Button("Load more reports") { Task { await self.store.refresh(using: client, more: true) }
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(self.store.isLoading)
                }
                if let coverage = self.store.coverage {
                    Text(coverage.hasMore
                        ? "More records remain in this snapshot."
                        : "End of this scoped snapshot. Other work may exist outside it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    @ViewBuilder
    private func records(_ items: [ArgusOperation], heading: String) -> some View {
        if !items.isEmpty {
            Text(heading).font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(items) { item in
                if let client {
                    NavigationLink {
                        ArgusOperationDetailView(operation: item, client: client)
                    } label: {
                        ArgusOperationRow(item: item, showsAction: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    ArgusOperationRow(item: item)
                }
            }
        }
    }
}

private struct ArgusOperationRow: View {
    let item: ArgusOperation
    var showsAction = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(self.item.heading).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text(self.item.recordSummary).font(.subheadline).foregroundStyle(.secondary)
            Label(self.item.recordLabel, systemImage: "doc.text")
                .font(.caption)
            Text("Report dated \(ArgusOperation.observationLabel(self.item.occurredAt))").font(.caption)
                .foregroundStyle(.secondary)
            if self.showsAction {
                Label(self.item.detailActionLabel, systemImage: "arrow.right")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(OpenClawBrand.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct ArgusArtifactButtonLabel: View {
    let artifact: ArgusOperation.Artifact
    let operationLabel: String?

    var body: some View {
        Label(
            "\(self.artifact.buttonLabel(operationLabel: self.operationLabel)) · \(self.artifact.byteCountLabel)",
            systemImage: "doc.viewfinder")
    }
}

/// A newly qualified route must retry pending reads even when connectivity was already restored.
/// These public generation values trigger view work; full route admission remains in the RPC client.
struct ArgusOperationDetailTaskID: Equatable {
    let isVisible: Bool
    let sameGateway: Bool
    let isConnected: Bool
    let routeGeneration: UInt64?
    let socketGeneration: UInt64?
}

struct ArgusOperationDetailView: View {
    @Environment(NodeAppModel.self) private var appModel
    let operation: ArgusOperation
    let client: ArgusOperationsClient
    @State private var detail: ArgusOperationDetail?
    @State private var error: String?
    @State private var artifactOpen = ArgusArtifactOpenStore()
    @State private var isVisible = false
    @State private var detailLoadGeneration = 0
    @State private var skipInitialLoad = false
    @State private var showArtifactSheet = false
    @State private var artifactOwnerGeneration = 0

    init(
        operation: ArgusOperation,
        client: ArgusOperationsClient,
        initialDetail: ArgusOperationDetail? = nil,
        initialArtifactSHA: String? = nil)
    {
        self.operation = operation
        self.client = client
        self._detail = State(initialValue: initialDetail)
        self._skipInitialLoad = State(initialValue: initialDetail != nil)
        self._artifactOpen = State(initialValue: ArgusArtifactOpenStore(initialArtifactSHA: initialArtifactSHA))
    }

    private var sameGateway: Bool {
        self.appModel.chatOutboxGatewayOwnerID == self.client.gatewayID
    }

    private var requestedItem: ArgusOperation { self.detail?.requested ?? self.operation }

    private var briefing: ArgusArtifactPreview? {
        guard self.sameGateway else { return nil }
        return self.appModel.argusBriefingCache.value(for: self.requestedItem, owner: self.client.gatewayID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !self.sameGateway {
                    Text("The paired gateway changed. Return Home to load its evidence.")
                } else {
                    if self.requestedItem.briefingArtifact != nil {
                        Text(self.requestedItem.heading).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        Text("Recorded \(ArgusOperation.observationLabel(self.requestedItem.occurredAt))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let briefing = self.briefing {
                            ArgusBriefingContent(preview: briefing)
                        } else if self.appModel.isOperatorGatewayConnected, self.error == nil,
                                  self.artifactOpen.error == nil {
                            ProgressView("Opening briefing")
                        } else {
                            Text("Briefing text is unavailable. Reconnect to retrieve this exact recorded item.")
                        }
                    } else {
                        ArgusOperationRow(item: self.detail?.item ?? self.operation)
                    }
                    if !self.appModel.isOperatorGatewayConnected {
                        Label(self.briefing == nil ? "Offline — last observed detail"
                            : "Offline — briefing retained for this app session", systemImage: "wifi.slash")
                    }
                    if let error {
                        Text(error).foregroundStyle(.secondary)
                    }
                    if let error = self.artifactOpen.error {
                        Text(error).foregroundStyle(.secondary)
                    }
                    if let detail {
                        if self.requestedItem.briefingArtifact != nil {
                            DisclosureGroup("Report details and earlier observations") {
                                self.evidenceContent(detail)
                            }
                        } else {
                            self.evidenceContent(detail)
                        }
                    } else if self.error == nil {
                        ProgressView("Loading detail")
                    }
                }
            }
            .padding()
        }
        .navigationTitle(self.requestedItem.briefingArtifact == nil ? "Report" : "Briefing")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ArgusOperationDetailTaskID(
            isVisible: self.isVisible,
            sameGateway: self.sameGateway,
            isConnected: self.appModel.isOperatorGatewayConnected,
            routeGeneration: self.client.pinnedRoute?.diagnosticRouteGeneration,
            socketGeneration: self.client.pinnedRoute?.diagnosticSocketGeneration))
        {
            self.appModel.argusBriefingCache.selectOwner(self.appModel.chatOutboxGatewayOwnerID)
            self.detailLoadGeneration += 1
            if self.isVisible, self.sameGateway, self.appModel.isOperatorGatewayConnected {
                if self.skipInitialLoad {
                    self.skipInitialLoad = false
                } else {
                    await self.load()
                }
                guard !Task.isCancelled, self.isVisible, self.sameGateway else { return }
                if let detail = self.detail {
                    // A corrected current observation must never substitute its artifact for the tapped event.
                    if detail.requested.briefingArtifact != nil {
                        await self.loadBriefing(detail.requested)
                    } else {
                        let generation = self.appModel.argusBriefingCache.generation
                        await self.artifactOpen.openPendingArtifact(for: detail.requested, fetch: self.fetchArtifact)
                        guard generation == self.appModel.argusBriefingCache.generation,
                              self.sameGateway, !Task.isCancelled else { self.artifactOpen.invalidate(); return }
                        self.artifactOwnerGeneration = generation
                        self.showArtifactSheet = self.artifactOpen.preview != nil
                    }
                }
            }
        }
        .refreshable {
            await self.load()
            if let detail = self.detail { await self.loadBriefing(detail.requested) }
        }
            .sheet(item: Binding(
                get: {
                    self.showArtifactSheet && self.artifactOwnerGeneration == self.appModel.argusBriefingCache.generation
                        ? self.artifactOpen.preview : nil
                },
                set: { _ in self.showArtifactSheet = false; self.artifactOpen.dismissPreview() }))
            { preview in
                NavigationStack {
                    ArgusArtifactView(preview: preview)
                        .navigationTitle("Verified artifact")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Done") { self.artifactOpen.dismissPreview() } }
                }
            }
            .onChange(of: self.sameGateway) { _, same in
                    self.appModel.argusBriefingCache.selectOwner(self.appModel.chatOutboxGatewayOwnerID)
                    self.artifactOpen.setAvailable(self.isVisible && same && self.appModel.isOperatorGatewayConnected)
                    if !same {
                        self.detail = nil
                    }
                }
                .onChange(of: self.appModel.isOperatorGatewayConnected) { _, connected in
                    self.artifactOpen.setAvailable(self.isVisible && self.sameGateway && connected)
                }
                .onAppear {
                    self.isVisible = true
                    self.artifactOpen.setAvailable(self.sameGateway && self.appModel.isOperatorGatewayConnected)
                }
                .onDisappear {
                    self.isVisible = false
                    self.artifactOpen.setAvailable(false)
                }
    }

    private func evidenceContent(_ detail: ArgusOperationDetail) -> some View {
        ArgusOperationEvidenceContent(
            detail: detail,
            artifactsAvailable: !self.artifactOpen.isLoading && self.appModel.isOperatorGatewayConnected,
            openArtifact: { artifact, item in
                Task { await self.openArtifact(artifact, item: item) }
            })
    }

    private func loadBriefing(_ item: ArgusOperation) async {
        guard self.sameGateway, self.isVisible, self.appModel.isOperatorGatewayConnected,
              let artifact = item.briefingArtifact else { return }
        let cache = self.appModel.argusBriefingCache
        if cache.value(for: item, owner: self.client.gatewayID) != nil { return }
        let generation = cache.generation
        await self.artifactOpen.open(artifact, item: item, fetch: self.fetchArtifact)
        guard self.sameGateway, self.isVisible, !Task.isCancelled,
              cache.generation == generation, let preview = self.artifactOpen.preview else { return }
        cache.retain(preview, for: item, owner: self.client.gatewayID, generation: generation)
        if cache.value(for: item, owner: self.client.gatewayID) == nil {
            self.error = "This briefing could not be displayed as verified text. Its document is in Report details."
        }
    }

    private func load() async {
        guard self.sameGateway, !Task.isCancelled else { return }
        self.detailLoadGeneration += 1
        let generation = self.detailLoadGeneration
        do {
            let response = try await self.client.request(
                "argus.operations.detail", params: ArgusOperationDetail.requestParameters(for: self.operation),
                as: ArgusOperationDetail.self)
            guard self.sameGateway, generation == self.detailLoadGeneration, !Task.isCancelled else { return }
            try response.validate(for: self.operation)
            self.detail = response
            self.error = nil
        } catch {
            guard generation == self.detailLoadGeneration, !Task.isCancelled else { return }
            self.error = "Detail unavailable. Previously observed evidence remains visible."
        }
    }

    private func openArtifact(_ artifact: ArgusOperation.Artifact, item: ArgusOperation) async {
        guard self.sameGateway, self.appModel.isOperatorGatewayConnected else { return }
        let generation = self.appModel.argusBriefingCache.generation
        await self.artifactOpen.open(artifact, item: item, fetch: self.fetchArtifact)
        guard generation == self.appModel.argusBriefingCache.generation, self.sameGateway,
              self.isVisible, !Task.isCancelled else { self.artifactOpen.invalidate(); return }
        self.artifactOwnerGeneration = generation
        self.showArtifactSheet = self.artifactOpen.preview != nil
    }

    private func fetchArtifact(_ params: [String: String]) async throws -> ArgusOperationArtifact {
        let response = try await self.client.request(
            "argus.operations.artifact", params: params, as: ArgusOperationArtifact.self)
        guard self.sameGateway, self.isVisible, self.appModel.isOperatorGatewayConnected,
              !Task.isCancelled else { throw ArgusOperationsError.unavailable }
        return response
    }
}

struct ArgusBriefingContent: View {
    let preview: ArgusArtifactPreview

    var body: some View {
        if preview.mimeType == "text/plain", let text = String(data: preview.data, encoding: .utf8) {
            VStack(alignment: .leading, spacing: 16) {
                Text(Self.formattedBody(text))
                    .font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Self.links(in: text), id: \.absoluteString) { url in
                    Link(destination: url) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Open \(url.lastPathComponent.isEmpty ? "linked work" : url.lastPathComponent)")
                            Text(url.host ?? "").font(.caption)
                        }
                    }
                }
            }
        }
    }

    static func formattedBody(_ text: String) -> AttributedString {
        var body = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        // Parsed Markdown must not create a second actionable URL path. Only
        // the bounded HTTPS controls below open links and disclose their host.
        body.link = nil
        return body
    }

    static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        var links: [URL] = []
        detector.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            guard let url = match?.url, url.scheme == "https", url.user == nil, url.password == nil,
                  seen.insert(url.absoluteString).inserted else { return }
            links.append(url)
            if links.count == 32 { stop.pointee = true }
        }
        return links
    }
}

/// The detail screen and synthetic visual fixtures share this exact evidence hierarchy.
struct ArgusOperationEvidenceContent: View {
    let detail: ArgusOperationDetail
    let artifactsAvailable: Bool
    let openArtifact: (ArgusOperation.Artifact, ArgusOperation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if self.detail.item.eventId != self.detail.requested.eventId {
                Text("A newer observation is available for this task.").font(.subheadline)
            }
            if self.detail.item.artifactContext?.relation == "previous_attempt" {
                Text("These artifacts belong to a previous attempt, not the current result.")
                    .font(.subheadline)
            }
            if !self.detail.item.artifacts.isEmpty {
                Text(self.detail.item.artifactContext?.relation == "previous_attempt" ? "Previous attempt artifacts"
                    : self.detail.item.artifactContext?.relation == "current_attempt" ? "Current attempt artifacts"
                    : "Recorded artifacts").font(.headline).accessibilityAddTraits(.isHeader)
                self.artifactButtons(for: self.detail.item)
            }
            if let work = self.detail.workContract {
                ArgusWorkSummary(work: work, artifactContext: self.detail.item.artifactContext)
            }
            DisclosureGroup("Source and provenance") {
                self.provenance(for: self.detail.item)
            }
            if let history = self.detail.reviewHistory {
                DisclosureGroup("Recorded reviews") {
                    ArgusReviewHistorySummary(history: history)
                }
            }
            DisclosureGroup("Earlier observations") {
                ForEach(
                    self.detail.displayTimeline.filter { $0.eventId != self.detail.item.eventId },
                    id: \.eventId)
                { item in
                    Text("Earlier observation — artifacts belong to this recorded event.").font(.caption)
                    ArgusOperationRow(item: item)
                    self.artifactButtons(for: item)
                    DisclosureGroup("Source and provenance") { self.provenance(for: item) }
                }
            }
            if self.detail.coverage.hasMore {
                Text("Timeline coverage is partial.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func artifactButtons(for item: ArgusOperation) -> some View {
        ForEach(item.artifacts) { artifact in
            Button {
                self.openArtifact(artifact, item)
            } label: {
                ArgusArtifactButtonLabel(artifact: artifact, operationLabel: item.display?.artifactLabel)
            }
            .accessibilityLabel(
                "Open artifact \(artifact.buttonLabel(operationLabel: item.display?.artifactLabel)) for \(item.heading), \(artifact.byteCountLabel)")
            .disabled(!self.artifactsAvailable)
        }
    }

    private func provenance(for item: ArgusOperation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
            Text("\(item.project) · \(item.source) · \(item.kind)")
            Text("Operation: \(item.id)")
            Text("Task: \(item.taskId)")
            Text("Event: \(item.eventId)")
            if let superseded = item.supersedesEventId {
                Text("Corrects event: \(superseded)")
            }
            Text("Recorded state: \(item.state.replacingOccurrences(of: "_", with: " "))")
            Text("Report dated: \(item.occurredAt)")
            Text("Observed: \(item.observedAt)")
            Text("The original event alone does not establish owner acceptance.")
        }
        .font(.subheadline)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ArgusArtifactView: View {
    let preview: ArgusArtifactPreview

    var body: some View {
        if self.preview.mimeType == "text/plain", let text = String(data: self.preview.data, encoding: .utf8) {
            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
        } else if self.preview.mimeType == "application/pdf", let document = PDFDocument(data: self.preview.data) {
            ArgusPDFView(document: document)
        } else if self.preview.mimeType.hasPrefix("image/"), let image = self.thumbnail {
            ScrollView { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Verified evidence image") }
        } else {
            Text("This artifact cannot be displayed.").padding()
        }
    }

    private var thumbnail: UIImage? {
        guard let source = CGImageSourceCreateWithData(
            self.preview.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2400,
            ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct ArgusPDFView: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context _: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = self.document
        return view
    }

    func updateUIView(_ view: PDFView, context _: Context) {
        if view.document !== self.document {
            view.document = self.document
        }
    }
}
