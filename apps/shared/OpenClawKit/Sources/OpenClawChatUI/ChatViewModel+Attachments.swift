import Foundation
import OpenClawKit
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

typealias ChatAttachmentURLReceiver = @MainActor @Sendable ([URL]) -> Bool
typealias ChatImageAttachmentReceiver = @MainActor @Sendable (Data, String, String) -> Bool

extension OpenClawChatViewModel {
    func loadAttachments(urls: [URL], generation: UInt64) async {
        for url in urls {
            guard self.canAcceptAttachment(generation: generation) else { return }
            do {
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                await self.addImageAttachment(
                    url: url,
                    data: data,
                    fileName: url.lastPathComponent,
                    mimeType: Self.mimeType(for: url) ?? "application/octet-stream",
                    generation: generation)
            } catch {
                guard self.canAcceptAttachment(generation: generation) else { return }
                await MainActor.run { self.errorText = error.localizedDescription }
            }
        }
    }

    static func mimeType(for url: URL) -> String? {
        let ext = url.pathExtension
        guard !ext.isEmpty else { return nil }
        return (UTType(filenameExtension: ext) ?? .data).preferredMIMEType
    }

    func addImageAttachment(
        url: URL?, data: Data, fileName: String, mimeType: String, generation: UInt64,
        processor: (@Sendable (Data) async throws -> Data)? = nil) async
    {
        guard self.canAcceptAttachment(generation: generation) else { return }
        let uti: UTType = {
            if let url {
                return UTType(filenameExtension: url.pathExtension) ?? .data
            }
            return UTType(mimeType: mimeType) ?? .data
        }()
        guard uti.conforms(to: .image) else {
            self.errorText = "Only image attachments are supported right now"
            return
        }

        let processed: Data
        do {
            if let processor {
                processed = try await processor(data)
            } else {
                processed = try await Task.detached(priority: .userInitiated) {
                    try ChatImageProcessor.processForUpload(data: data)
                }.value
            }
        } catch {
            guard self.canAcceptAttachment(generation: generation) else { return }
            self.errorText = "Could not process \(fileName): \(error.localizedDescription)"
            return
        }

        guard self.canAcceptAttachment(generation: generation) else { return }

        if processed.count > Self.maxAttachmentBytes {
            self.errorText = "Attachment \(fileName) exceeds 5 MB limit after resizing"
            return
        }

        let outputFileName: String = {
            let baseName = (fileName as NSString).deletingPathExtension
            return baseName.isEmpty ? "image.jpg" : "\(baseName).jpg"
        }()

        let preview = Self.previewImage(data: processed)
        self.attachments.append(
            OpenClawPendingAttachment(
                url: url,
                data: processed,
                fileName: outputFileName,
                mimeType: "image/jpeg",
                preview: preview))
    }

    static func previewImage(data: Data) -> OpenClawPlatformImage? {
        #if canImport(AppKit)
        NSImage(data: data)
        #elseif canImport(UIKit)
        UIImage(data: data)
        #else
        nil
        #endif
    }
}
