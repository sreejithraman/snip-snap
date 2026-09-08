import Foundation
import SnipSnapCore
import SnipSnapPersistence
@preconcurrency import UIKit
import UniformTypeIdentifiers

@MainActor
enum ShareExtensionInputLoader {
    static func load(
        items: [NSExtensionItem],
        staging: ShareImportStagingArea
    ) async throws -> (
        text: String, attachments: [ShareImportAttachment], richTextRepresentations: [ClipboardRepresentation]
    ) {
        var textParts: [String] = []
        var attachments: [ShareImportAttachment] = []
        var richTextCandidates: [(text: String, representation: ClipboardRepresentation)] = []
        for item in items {
            let attributedText = item.attributedContentText?.string
            let hasAttributedText = attributedText?.isEmpty == false
            if let attributedText, hasAttributedText {
                textParts.append(attributedText)
                if let richText = item.attributedContentText,
                    let data = try? richText.data(
                        from: NSRange(location: 0, length: richText.length),
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                    )
                {
                    richTextCandidates.append((attributedText,
                        ClipboardRepresentation(type: UTType.rtf.identifier, data: data)))
                }
            }
            for provider in item.attachments ?? [] {
                let part = try await load(
                    provider: provider,
                    staging: staging,
                    hasTextFallback: hasAttributedText
                )
                switch part {
                case .text(let text):
                    textParts.append(text)
                case .attachment(let attachment):
                    attachments.append(attachment)
                case .richText(let text, let representation):
                    textParts.append(text)
                    richTextCandidates.append((text, representation))
                case .none:
                    break
                }
            }
        }
        let text = textParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { parts, value in
                if !parts.contains(value) { parts.append(value) }
            }
            .joined(separator: "\n\n")
        // Keep a rich representation only when it covers all shared text.
        // A separate caption or URL must never disappear when another app pastes RTF.
        let richText = richTextCandidates.first {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
        }.map { [$0.representation] } ?? []
        return (text, attachments, richText)
    }

    private enum Part {
        case text(String)
        case attachment(ShareImportAttachment)
        case richText(String, ClipboardRepresentation)
        case none
    }

    private static func load(
        provider: NSItemProvider,
        staging: ShareImportStagingArea,
        hasTextFallback: Bool
    ) async throws -> Part {
        if let imageType = preferredType(in: provider, conformingTo: .image) {
            return .attachment(
                try await copyFileRepresentation(
                    provider: provider,
                    type: imageType,
                    staging: staging
                )
            )
        }

        if let fileURLType = preferredType(in: provider, conformingTo: .fileURL) {
            return .attachment(
                try await copyURLObject(
                    provider: provider,
                    type: fileURLType,
                    staging: staging
                )
            )
        }

        if provider.canLoadObject(ofClass: URL.self),
            let url = try await loadURL(provider)
        {
            guard !url.isFileURL else { throw ShareImportError.invalidStaging }
            return .text(url.absoluteString)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier),
            let data = try? await loadRTF(provider),
            let attributed = try? NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
        {
            return .richText(attributed.string, ClipboardRepresentation(type: UTType.rtf.identifier, data: data))
        }

        if provider.canLoadObject(ofClass: String.self) {
            do {
                if let text = try await loadText(provider) {
                    return .text(text)
                }
            } catch where hasTextFallback {
                return .none
            }
        }

        if let type = preferredFileType(in: provider) {
            return .attachment(
                try await copyFileRepresentation(
                    provider: provider,
                    type: type,
                    staging: staging
                )
            )
        }
        return .none
    }

    private static func preferredType(
        in provider: NSItemProvider,
        conformingTo parent: UTType
    ) -> UTType? {
        provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .first(where: { $0.conforms(to: parent) })
    }

    private static func preferredFileType(in provider: NSItemProvider) -> UTType? {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        return types.first(where: {
            $0.conforms(to: .content) && !$0.conforms(to: .url) && !$0.conforms(to: .text)
        }) ?? types.first(where: { $0.conforms(to: .data) })
    }

    private static func loadURL(_ provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: object)
                }
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: object)
                }
            }
        }
    }

    private static func loadRTF(_ provider: NSItemProvider) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.rtf.identifier) { data, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data) }
            }
        }
    }

    private static func copyFileRepresentation(
        provider: NSItemProvider,
        type: UTType,
        staging: ShareImportStagingArea
    ) async throws -> ShareImportAttachment {
        try await ShareProviderFileLoader.copyFileRepresentation(
            staging: staging,
            suggestedName: provider.suggestedName,
            contentType: type.identifier
        ) { completion in
            _ = provider.loadFileRepresentation(
                forTypeIdentifier: type.identifier,
                completionHandler: completion
            )
        }
    }

    private static func copyURLObject(
        provider: NSItemProvider,
        type: UTType,
        staging: ShareImportStagingArea
    ) async throws -> ShareImportAttachment {
        try await ShareProviderFileLoader.copyFileRepresentation(
            staging: staging,
            suggestedName: provider.suggestedName,
            contentType: type.identifier
        ) { completion in
            _ = provider.loadObject(ofClass: URL.self) { object, error in
                completion(object, error)
            }
        }
    }
}
