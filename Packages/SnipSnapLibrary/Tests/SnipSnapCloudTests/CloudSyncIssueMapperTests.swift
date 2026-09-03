import CloudKit
import SnipSnapCore
@testable import SnipSnapCloud
import XCTest

final class CloudSyncIssueMapperTests: XCTestCase {
  func testCloudKitRetryStatesMapToCalmAutomaticStatuses() {
    XCTAssertEqual(
      SnipSnapCloudSyncIssueMapper.issue(for: CKError(.networkUnavailable)),
      .waitingForConnection
    )
    XCTAssertEqual(
      SnipSnapCloudSyncIssueMapper.issue(for: CKError(.networkFailure)),
      .iCloudUnavailable
    )
    XCTAssertEqual(
      SnipSnapCloudSyncIssueMapper.issue(for: CKError(.requestRateLimited)),
      .retryingSoon
    )
  }

  func testCloudKitUserActionStatesStayDistinct() {
    XCTAssertEqual(
      SnipSnapCloudSyncIssueMapper.issue(for: CKError(.quotaExceeded)),
      .iCloudStorageFull
    )
    XCTAssertEqual(
      SnipSnapCloudSyncIssueMapper.issue(for: CKError(.incompatibleVersion)),
      .updateRequired
    )
    XCTAssertEqual(
      SnipSnapCloudSyncIssueMapper.issue(for: CKError(.permissionFailure)),
      .accessDenied
    )
  }

  func testInternalRecordCodesMapWithoutLeakingTheirCodes() {
    XCTAssertEqual(
      SnipSnapCloudSyncIssueMapper.issue(for: CloudRecordError.mismatchedShadow),
      .appDataIssue
    )
    XCTAssertEqual(
      SnipSnapCloudSyncIssueMapper.issue(for: CloudRecordError.wrongRecordType),
      .appDataIssue
    )
  }

  func testAttachmentErrorsMapToAttachmentStatuses() {
    XCTAssertEqual(
      SnipSnapCloudSyncIssueMapper.issue(for: CKError(.assetFileNotFound)),
      .attachmentMissing
    )
    XCTAssertEqual(
      SnipSnapCloudSyncIssueMapper.issue(for: CKError(.assetNotAvailable)),
      .attachmentUnavailable
    )
    XCTAssertEqual(
      SnipSnapCloudSyncIssueMapper.issue(for: CloudRecordError.invalidAssetDestination),
      .attachmentStorageUnavailable
    )
  }

  func testPartialFailureUsesTheRootItemError() {
    let error = CKError(
      .partialFailure,
      userInfo: [
        CKPartialErrorsByItemIDKey: ["one": CKError(.quotaExceeded)]
      ]
    )

    XCTAssertEqual(
      SnipSnapCloudSyncIssueMapper.issue(for: error),
      .iCloudStorageFull
    )
  }

  func testExpiredTokensStayDistinctAndTemporaryAccountErrorsDoNotUseTimerRetry() {
    XCTAssertEqual(
      CloudKitRecordTransport.failure(CKError(.changeTokenExpired)),
      .changeTokenExpired
    )
    XCTAssertFalse(CloudKitRetryPolicy.isTransient(.accountTemporarilyUnavailable))
  }

  func testBatchAuthenticationFailureKeepsCheckingAccountStatus() {
    let batch = CloudFetchedBatch(
      id: UUID(),
      items: [],
      databaseEvents: [.failed(nil, .authenticationRequired)],
      engineState: nil
    )

    XCTAssertEqual(CloudSyncIssueError.issue(in: .fetched(batch)), .checkingAccount)
  }
}
