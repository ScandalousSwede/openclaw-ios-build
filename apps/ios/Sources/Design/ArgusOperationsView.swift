import ImageIO
import PDFKit
import SwiftUI

struct ArgusOperationsSection: View {
    @Environment(NodeAppModel.self) private var appModel
    @State private var store = ArgusOperationsStore()

    private var client: ArgusOperationsClient? {
        guard !self.appModel.isAppleReviewDemoModeEnabled,
              self.appModel.isOperatorGatewayConnected,
              let id = self.appModel.chatOutboxGatewayOwnerID else { return nil }
        return ArgusOperationsClient(session: self.appModel.operatorSession, gatewayID: id)
    }

    var body: some View {
        CommandPanel(padding: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text("External technical evidence")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Observations from other tools. These do not establish active work, completion or owner acceptance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text("No external evidence found in the Argus federation scope.")
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
        .task(id: "\(self.appModel.chatOutboxGatewayOwnerID ?? "none")|\(self.client != nil)") {
            self.store.selectGateway(self.appModel.chatOutboxGatewayOwnerID)
            if let client { await self.store.refresh(using: client) }
            else { self.store.markUnavailable() }
        }
    }
}

private struct ArgusOperationRow: View {
    let item: ArgusOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(self.item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text("\(self.item.source) · \(self.item.kind)").font(.caption).foregroundStyle(.secondary)
            Label(self.item.supersedesEventId == nil ? "Observed" : "Correction observed", systemImage: "doc.text")
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

    private var sameGateway: Bool { self.appModel.chatOutboxGatewayOwnerID == self.client.gatewayID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !self.sameGateway {
                    Text("The paired gateway changed. Return Home to load its evidence.")
                } else {
                    ArgusOperationRow(item: self.detail?.item ?? self.operation)
                    Text("Owner acceptance has not been established. This is a recorded external observation.")
                        .font(.subheadline)
                    if !self.appModel.isOperatorGatewayConnected {
                        Label("Offline — last observed detail", systemImage: "wifi.slash")
                    }
                    if let error { Text(error).foregroundStyle(.secondary) }
                    if let detail {
                        Text("Evidence timeline").font(.headline).accessibilityAddTraits(.isHeader)
                        if detail.item.id != detail.requested.id {
                            Text("A later observation supersedes the selected result.").font(.subheadline)
                        }
                        ForEach(detail.timeline) { item in
                            ArgusOperationRow(item: item)
                            ForEach(item.artifacts) { artifact in
                                Button {
                                    Task { await self.openArtifact(artifact, item: item) }
                                } label: {
                                    Label("Open artifact · \(artifact.bytes) bytes", systemImage: "doc.viewfinder")
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
        .task { await self.load() }
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
        guard self.sameGateway else { return }
        do {
            let response = try await self.client.request(
                "argus.operations.detail", params: ["operation_id": self.operation.id], as: ArgusOperationDetail.self)
            guard self.sameGateway else { return }
            guard response.requested.id == self.operation.id, !response.ownerAccepted,
                  response.timeline.count <= 100,
                  ([response.item, response.requested] + response.timeline).allSatisfy({
                      $0.project == "Argus" && !$0.ownerAccepted && $0.state == "observed"
                          && $0.taskId == self.operation.taskId && $0.source == self.operation.source
                  })
            else { throw ArgusOperationsError.invalidResponse }
            self.detail = response
            self.error = nil
        } catch { self.error = "Detail unavailable. Previously observed evidence remains visible." }
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
