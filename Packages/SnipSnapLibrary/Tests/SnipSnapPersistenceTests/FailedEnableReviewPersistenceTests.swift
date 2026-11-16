import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
import XCTest

final class FailedEnableReviewPersistenceTests: XCTestCase {
    func testMalformedReviewOrDecisionCannotReplaceTheDurableBundle() throws {
        // These are negative codec inputs only. No live mode owner consumes a fabricated review.
        for defect in ReviewCodecDefect.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewCodec-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let sourceID = UUID()
            let file = FailedEnableEvidenceFile(root: root)
            let baseline = emptyBundle(sourceID: sourceID)
            try file.update(sourceID) { _ in baseline }
            let oldBytes = try Data(contentsOf: file.url(sourceID))
            let invalid = try invalidBundle(sourceID: sourceID, defect: defect)
            XCTAssertThrowsError(try file.update(sourceID) { _ in invalid }, "\(defect)")
            XCTAssertEqual(try Data(contentsOf: file.url(sourceID)), oldBytes, "\(defect)")
            let decoded = try file.read(sourceID)
            let after = try XCTUnwrap(decoded)
            XCTAssertTrue(after.namespaces.isEmpty)
        }
    }

    private func emptyBundle(sourceID: UUID) -> FailedEnableInstalledEvidence {
        FailedEnableInstalledEvidence(version: 1, purpose: .installedEvidence,
            sourceStoreID: FailedEnableEncoding.uuid(sourceID), sequence: "0",
            continuity: FailedEnableContinuity(state: .verified,
                activationDigest: String(repeating: "0", count: 64), sourceRevision: "0",
                sourceDigest: String(repeating: "0", count: 64), inFlight: .init(nil)),
            namespaces: [], transfers: [], blobs: [:])
    }

    private func invalidBundle(sourceID: UUID, defect: ReviewCodecDefect) throws -> FailedEnableInstalledEvidence {
        let attachmentID = UUID()
        let bytes = Data("codec-owned bytes".utf8)
        let attachment = SnipAttachment(id: attachmentID, fileName: "codec.txt",
            relativePath: "\(attachmentID.uuidString)/codec.txt", contentType: "public.plain-text",
            byteCount: Int64(bytes.count))
        let snip = Snip(createdAt: Date(timeIntervalSince1970: 10), content: "retained codec value",
            origin: .quickEntry, attachments: [attachment])
        let image = FailedEnableImage.snip(try FailedEnableSnipImage(snip, attachmentData: [attachmentID: bytes]))
        let reference = FailedEnableReference(CloudEntityReference(kind: .snip, domainID: snip.id))
        let outputID = defect == .outputCollision ? snip.id : UUID()
        let requestID = defect == .requestCollision ? outputID : UUID()
        let copiedAttachmentID = defect == .attachmentCollision ? requestID : UUID()
        let map = FailedEnableCopyIDs(original: reference,
            output: FailedEnableReference(CloudEntityReference(
                kind: defect == .wrongOutputKind ? .list : .snip, domainID: outputID)),
            requestID: .init(FailedEnableEncoding.uuid(requestID)),
            attachments: [FailedEnableAttachmentCopyID(originalID: FailedEnableEncoding.uuid(attachmentID),
                newID: FailedEnableEncoding.uuid(copiedAttachmentID))])
        let decision = FailedEnableReviewDecision(choice: .recoverAsNew,
            fieldMask: defect == .unknownSelectedField ? ["text", "madeUpField"]
                : ["isDone", "pinnedAt", "placement", "source", "text"],
            selectedImage: .init(image), outputIDs: [map], resolvedAlternativeIDs: [])
        let local = FailedEnableLocalExpectation(
            sourceStoreID: FailedEnableEncoding.uuid(defect == .wrongSource ? UUID() : sourceID),
            sourceRevision: "0", sourceDigest: String(repeating: "0", count: 64),
            membership: .present, image: .init(image))
        let server = FailedEnableServerExpectation(
            state: defect == .valueWithoutArchive ? .value : .deleted,
            observation: .init(nil), acceptedRevisionDigest: .init(nil))
        let review = FailedEnableReview(id: FailedEnableEncoding.uuid(UUID()),
            reference: defect == .wrongImage ? FailedEnableReference(CloudEntityReference(kind: .snip, domainID: UUID())) : reference,
            identity: .init(nil), reason: .unknownOutcome,
            issueDigest: defect == .invalidIssueDigest ? "not-a-digest" : String(repeating: "0", count: 64),
            local: local, server: server,
            earlierAlternativeIDs: defect == .missingEarlierVersion ? [FailedEnableEncoding.uuid(UUID())] : [],
            decision: .init(decision))
        let binding = ICloudSyncNamespaceBinding(scope: "private", accountLineage: "codec-account",
            generation: UUID(), zones: [ICloudSyncZoneBinding(name: "metadata", ownerName: "owner")])
        var result = emptyBundle(sourceID: sourceID)
        result.blobs = defect == .missingBytes ? [:] : [FailedEnableEncoding.digest(bytes): bytes]
        result.namespaces = [FailedEnableNamespace(binding: FailedEnableBinding(binding), captures: [], alternatives: [],
            reviews: defect == .duplicateIssue ? [review, review] : [review])]
        return result
    }
}

private enum ReviewCodecDefect: CaseIterable, Equatable {
    case duplicateIssue, wrongSource, wrongImage, invalidIssueDigest, unknownSelectedField
    case missingBytes, outputCollision, requestCollision, attachmentCollision, wrongOutputKind
    case valueWithoutArchive, missingEarlierVersion
}
