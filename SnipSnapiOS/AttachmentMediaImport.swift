import CoreTransferable
import Foundation
import ImageIO
import PhotosUI
import SnipSnapCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AttachmentSource {
    case files
    case photos
    case camera
}

struct AttachmentSourceMenu<Label: View>: View {
    @State private var isChoosing = false
    var title: LocalizedStringKey = "Add an attachment"
    let choose: (AttachmentSource) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: { isChoosing = true }, label: label)
            .confirmationDialog(
                title,
                isPresented: $isChoosing,
                titleVisibility: .visible
            ) {
                Button("Choose Files") { choose(.files) }
                Button("Choose Photos") { choose(.photos) }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo") { choose(.camera) }
                }
            }
    }
}

struct AttachmentCameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCapture: (UIImage?) -> Void

        init(onCapture: @escaping (UIImage?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            onCapture(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}

private final class TemporaryPhotoImport: @unchecked Sendable {
    let url: URL

    init(url: URL) { self.url = url }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

private struct PickedPhotoFile: Transferable, Sendable {
    let temporaryImport: TemporaryPhotoImport
    var url: URL { temporaryImport.url }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let values = try received.file.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw SnipLibraryError.attachmentCopyFailed
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SnipSnapPhotoImports", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let source = CGImageSourceCreateWithURL(received.file as CFURL, nil),
                  CGImageSourceGetCount(source) > 0,
                  let type = CGImageSourceGetType(source),
                  let fileExtension = UTType(type as String)?.preferredFilenameExtension else {
                try? FileManager.default.removeItem(at: directory)
                throw SnipLibraryError.attachmentCopyFailed
            }
            let url = directory.appendingPathComponent("Photo.\(fileExtension)")
            do {
                try FileManager.default.copyItem(at: received.file, to: url)
                return PickedPhotoFile(temporaryImport: TemporaryPhotoImport(url: url))
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
    }
}

private final class PhotoLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PickedPhotoFile?, Error>?
    private var progress: Progress?
    private var isCancelled = false

    func begin(_ continuation: CheckedContinuation<PickedPhotoFile?, Error>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setProgress(_ progress: Progress) {
        lock.lock()
        self.progress = progress
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel { progress.cancel() }
    }

    func finish(_ result: Result<PickedPhotoFile?, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let continuation = continuation
        self.continuation = nil
        let progress = progress
        lock.unlock()
        progress?.cancel()
        continuation?.resume(throwing: CancellationError())
    }
}

enum AttachmentMediaInput {
    case files([URL])
    case photos([PhotosPickerItem])
    case camera(UIImage)
}

enum AttachmentMediaStager {
    static func stage(_ input: AttachmentMediaInput, in root: URL) async throws -> [StagedAttachment] {
        switch input {
        case .files(let urls): try await AttachmentDraftStager.stage(urls, in: root)
        case .photos(let items): try await stagePhotos(items, in: root)
        case .camera(let image): [try await stageCameraImage(image, in: root)]
        }
    }

    static func stagePhotos(_ items: [PhotosPickerItem], in root: URL) async throws -> [StagedAttachment] {
        var imports: [PickedPhotoFile] = []
        defer { imports.removeAll() }
        for item in items {
            try Task.checkCancellation()
            let loaded = try await loadPhoto(item)
            try Task.checkCancellation()
            guard let file = loaded else {
                throw SnipLibraryError.attachmentCopyFailed
            }
            imports.append(file)
        }
        return try await AttachmentDraftStager.stage(imports.map(\.url), in: root)
    }

    private static func loadPhoto(_ item: PhotosPickerItem) async throws -> PickedPhotoFile? {
        let load = PhotoLoad()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                load.begin(continuation)
                let progress = item.loadTransferable(type: PickedPhotoFile.self) { result in
                    load.finish(result)
                }
                load.setProgress(progress)
            }
        } onCancel: {
            load.cancel()
        }
    }

    static func stageCameraImage(_ image: UIImage, in root: URL) async throws -> StagedAttachment {
        let batchDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = batchDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileName = "Photo.jpg"
        let url = directory.appendingPathComponent(fileName)
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let data = image.jpegData(compressionQuality: 0.9) else {
                throw SnipLibraryError.attachmentCopyFailed
            }
            try Task.checkCancellation()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                try Task.checkCancellation()
                return StagedAttachment(fileName: fileName, byteCount: Int64(data.count), url: url)
            } catch {
                try? FileManager.default.removeItem(at: batchDirectory)
                throw error
            }
        }
        let staged = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: batchDirectory)
            throw CancellationError()
        }
        return staged
    }
}
