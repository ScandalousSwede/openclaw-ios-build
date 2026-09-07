import ImageIO
import PDFKit
import SwiftUI

struct ArgusOperationsSection: View {
    @Environment(NodeAppModel.self) private var appModel
    @State private var store = ArgusOperationsStore()
    @Environment(\.scenePhase) private var scenePhase

    private var client: ArgusOperationsClient? {
        guard !self.appModel.isAppleReviewDemoModeEnabled,
              self.appModel.isOperatorGatewayConnected,
              let id = self.appModel.chatOutboxGatewayOwnerID else { return nil }
        return ArgusOperationsClient(session: self.appModel.operatorSession, gatewayID: id)
    }

    var body: some View {
        ArgusOperationsContent(store: self.store, client: self.client)
            .task(id: "\(self.appModel.chatOutboxGatewayOwnerID ?? "none")|\(self.client != nil)|\(self.scenePhase)|\(self.store.project.rawValue)") {
                self.store.selectGateway(self.appModel.chatOutboxGatewayOwnerID)
                // Invalidate suspended work from the previous visibility/route scope.
                self.store.markUnavailable()
                guard self.scenePhase == .active, let client else { return }
                while !Task.isCancelled {
                    await self.store.refresh(using: client)
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { return }
                }
            }
    }
}

struct ArgusOperationsContent: View {
    let store: ArgusOperationsStore
    let client: ArgusOperationsClient?

    var body: some View {
        CommandPanel(padding: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Work and technical evidence")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Canonical work and external observations. Recorded status does not establish owner acceptance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Evidence project", selection: Binding(
                    get: { self.store.project }, set: { self.store.selectProject($0) })) {
                    ForEach(ArgusEvidenceProject.allCases, id: \.self) { project in
                        Text(project.rawValue).tag(project)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Evidence project")
                if self.store.project != .argus {
                    Text("Technical observations only. This view does not control equipment or establish scientific authority.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if self.store.unavailable {
                    Label(self.store.items.isEmpty
                        ? "Evidence unavailable. Connect and refresh."
                        : "Offline or unavailable — showing last observed evidence.", systemImage: "wifi.slash")
                        .font(.subheadline)
                }
                if let observed = self.store.coverage?.observedAt {
                    Text("Last observed: \(observed)").font(.caption).foregroundStyle(.secondary)
                }
                if self.store.items.isEmpty, !self.store.unavailable, !self.store.isLoading {
                    Text("No evidence found in this returned \(self.store.project.rawValue) scope.")
                        .font(.subheadline)
                }
                ForEach(self.store.items) { item in
                    if let client {
                        NavigationLink {
                            ArgusOperationDetailView(operation: item, client: client)
                        } label: {
                            ArgusOperationRow(item: item)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ArgusOperationRow(item: item)
                    }
                }
                if self.store.isLoading { ProgressView("Loading evidence") }
                if let client {
                    HStack {
                        Button("Refresh") { Task { await self.store.refresh(using: client) } }
                        if self.store.nextCursor != nil {
                            Button("Load more evidence") { Task { await self.store.refresh(using: client, more: true) } }
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
}

private struct ArgusOperationRow: View {
    let item: ArgusOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(self.item.display?.label ?? self.item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            if let summary = self.item.display?.changeSummary { Text(summary).font(.subheadline) }
            Text("\(self.item.project) · \(self.item.source) · \(self.item.kind)").font(.caption).foregroundStyle(.secondary)
            Label(self.item.supersedesEventId == nil ? self.item.state.replacingOccurrences(of: "_", with: " ").capitalized : "Correction observed", systemImage: "doc.text")
                .font(.caption)
            Text("Observed \(self.item.observedAt)").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct ArgusArtifactPreview: Identifiable {
    let id: String
    let data: Data
    let mimeType: String
}

private struct ArgusOperationDetailView: View {
    @Environment(NodeAppModel.self) private var appModel
    let operation: ArgusOperation
    let client: ArgusOperationsClient
    @State private var detail: ArgusOperationDetail?
    @State private var error: String?
    @State private var preview: ArgusArtifactPreview?
    @State private var loadingArtifact = false
    @State private var detailLoadGeneration = 0

    private var sameGateway: Bool { self.appModel.chatOutboxGatewayOwnerID == self.client.gatewayID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !self.sameGateway {
                    Text("The paired gateway changed. Return Home to load its evidence.")
                } else {
                    ArgusOperationRow(item: self.detail?.item ?? self.operation)
                    Text("Owner acceptance has not been established. This view reports scoped recorded evidence.")
                        .font(.subheadline)
                    if !self.appModel.isOperatorGatewayConnected {
                        Label("Offline — last observed detail", systemImage: "wifi.slash")
                    }
                    if let error { Text(error).foregroundStyle(.secondary) }
                    if let detail {
                        if let work = detail.workContract {
                            ArgusWorkSummary(work: work, artifactContext: detail.item.artifactContext)
                        }
                        if let history = detail.reviewHistory {
                            ArgusReviewHistorySummary(history: history)
                        }
                        Text("Evidence timeline").font(.headline).accessibilityAddTraits(.isHeader)
                        if detail.item.id != detail.requested.id {
                            Text("A newer observation is available for this task.").font(.subheadline)
                        }
                        ForEach(detail.timeline, id: \.eventId) { item in
                            ArgusOperationRow(item: item)
                            ForEach(item.artifacts) { artifact in
                                Button {
                                    Task { await self.openArtifact(artifact, item: item) }
                                } label: {
                                    Label("\(item.display?.artifactLabel ?? "Open artifact") · \(artifact.bytes) bytes", systemImage: "doc.viewfinder")
                                }
                                .accessibilityLabel("Open verified artifact for \(item.title), \(artifact.bytes) bytes")
                                .disabled(self.loadingArtifact || !self.appModel.isOperatorGatewayConnected)
                            }
                        }
                        if detail.coverage.hasMore {
                            Text("Timeline coverage is partial.").font(.caption)
                        }
                    } else if self.error == nil { ProgressView("Loading detail") }
                }
            }
            .padding()
        }
        .navigationTitle("Evidence")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(self.sameGateway)|\(self.appModel.isOperatorGatewayConnected)") {
            self.detailLoadGeneration += 1
            if self.sameGateway, self.appModel.isOperatorGatewayConnected { await self.load() }
        }
        .refreshable { await self.load() }
        .sheet(item: self.$preview) { preview in
            NavigationStack {
                ArgusArtifactView(preview: preview)
                    .navigationTitle("Verified artifact")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { self.preview = nil } }
            }
        }
        .onChange(of: self.sameGateway) { _, same in
            if !same { self.detail = nil; self.preview = nil }
        }
    }

    private func load() async {
        guard self.sameGateway, !Task.isCancelled else { return }
        self.detailLoadGeneration += 1
        let generation = self.detailLoadGeneration
        do {
            let response = try await self.client.request(
                "argus.operations.detail", params: ["operation_id": self.operation.id], as: ArgusOperationDetail.self)
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
        guard self.sameGateway, !self.loadingArtifact else { return }
        self.loadingArtifact = true
        defer { self.loadingArtifact = false }
        do {
            let response = try await self.client.request(
                "argus.operations.artifact", params: ["operation_id": item.id, "sha256": artifact.sha256],
                as: ArgusOperationArtifact.self)
            let data = try response.validatedData(for: item.id, artifact: artifact)
            guard self.sameGateway else { return }
            self.preview = ArgusArtifactPreview(id: artifact.sha256, data: data, mimeType: response.mimeType)
            self.error = nil
        } catch { self.error = "Artifact unavailable or integrity verification failed. Nothing was opened." }
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
        if view.document !== self.document { view.document = self.document }
    }
}
