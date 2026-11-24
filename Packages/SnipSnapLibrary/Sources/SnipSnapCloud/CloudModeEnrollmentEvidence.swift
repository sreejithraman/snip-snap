import Foundation
import SnipSnapCore
import SnipSnapPersistence

package enum CloudNamespaceEnrollmentError: Error, Equatable, Sendable {
    case invalidSeedSelection
}

package struct CloudTextEnrollmentEvidence: Equatable, Sendable {
    package let phase: CloudNamespaceBootstrapPhase
    package let hasRetryableRecordFailures: Bool
    package let retryableEventKeys: Set<String>
    package let needsAttention: Bool
}

package enum CloudSyncRetryableError: Error, Equatable, Sendable {
    case itemFailure
}
