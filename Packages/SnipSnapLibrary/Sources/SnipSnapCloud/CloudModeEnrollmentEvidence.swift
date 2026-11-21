import Foundation
import SnipSnapCore
import SnipSnapPersistence

package enum CloudNamespaceEnrollmentError: Error, Equatable, Sendable {
    case remoteFetchRequired
    case invalidSeedSelection
}

package struct CloudTextEnrollmentEvidence: Equatable, Sendable {
    package let phase: CloudNamespaceBootstrapPhase
    package let hasPendingChanges: Bool
    package let hasRetryableRecordFailures: Bool
    package let retryableEventKeys: Set<String>
    package let needsAttention: Bool
    package let blocksSending: Bool
}

package enum CloudSyncRetryableError: Error, Equatable, Sendable {
    case itemFailure
}
