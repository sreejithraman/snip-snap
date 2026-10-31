import Observation
import ImageIO
import SnipSnapCore
import SnipSnapCloud
import SnipSnapPersistence
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SnipSnapiOS

@MainActor
final class RecordingPasteboard: IOSPasteboardWriting {
    private(set) var writes: [[IOSCopyItem]] = []
    var succeeds = true
    var onNextWrite: (() -> Void)?

    func write(_ items: [IOSCopyItem]) -> Bool {
        writes.append(items)
        let onWrite = onNextWrite
        onNextWrite = nil
        onWrite?()
        return succeeds
    }
}

func testAttachment(
    id: UUID,
    fileName: String,
    byteCount: Int64 = 1
) throws -> SnipAttachment {
    let json = """
    {
      "id": "\(id.uuidString)",
      "fileName": "\(fileName)",
      "relativePath": "\(id.uuidString)/\(fileName)",
      "contentType": "public.text",
      "byteCount": \(byteCount)
    }
    """
    return try JSONDecoder().decode(SnipAttachment.self, from: Data(json.utf8))
}

func thumbnailTestImage(width: Int = 4, height: Int = 3) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}
