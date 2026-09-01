@_spi(Maintainer) @testable import SnipSnapCloud
import XCTest

final class CloudDevelopmentTransportContractTests: XCTestCase {
    func testOperationFailureStillRetriesAndConfirmsZoneCleanup() async throws {
        let probe = CleanupProbe(deleteFailures: 1, zoneExistsResults: [true, false])

        do {
            try await CloudDevelopmentTransportContract.runWithCleanup(
                operation: { throw ProbeError.operation },
                cleanup: {
                    try await CloudDevelopmentTransportContract.cleanupZone(
                        delete: { try await probe.deleteZone() },
                        zoneExists: { await probe.zoneExists() }
                    )
                }
            )
            XCTFail("Expected the operation error after cleanup.")
        } catch {
            XCTAssertEqual(error as? ProbeError, .operation)
        }

        let calls = await probe.calls()
        XCTAssertEqual(calls.delete, 2)
        XCTAssertEqual(calls.verify, 2)
    }

    func testUnconfirmedCleanupFailsTheContractAfterThreeAttempts() async {
        let probe = CleanupProbe(deleteFailures: 3, zoneExistsResults: [true, true, true])

        do {
            try await CloudDevelopmentTransportContract.runWithCleanup(
                operation: {},
                cleanup: {
                    try await CloudDevelopmentTransportContract.cleanupZone(
                        delete: { try await probe.deleteZone() },
                        zoneExists: { await probe.zoneExists() }
                    )
                }
            )
            XCTFail("Expected unconfirmed cleanup to fail the contract.")
        } catch {
            XCTAssertEqual(
                error as? CloudDevelopmentTransportContract.ContractError,
                .zoneCleanupWasNotConfirmed
            )
        }

        let calls = await probe.calls()
        XCTAssertEqual(calls.delete, 3)
        XCTAssertEqual(calls.verify, 3)
    }
}

private enum ProbeError: Error {
    case operation
    case delete
}

private actor CleanupProbe {
    private var remainingDeleteFailures: Int
    private var remainingZoneExistsResults: [Bool]
    private var deleteCalls = 0
    private var verifyCalls = 0

    init(deleteFailures: Int, zoneExistsResults: [Bool]) {
        remainingDeleteFailures = deleteFailures
        remainingZoneExistsResults = zoneExistsResults
    }

    func deleteZone() throws {
        deleteCalls += 1
        if remainingDeleteFailures > 0 {
            remainingDeleteFailures -= 1
            throw ProbeError.delete
        }
    }

    func zoneExists() -> Bool {
        verifyCalls += 1
        return remainingZoneExistsResults.isEmpty
            ? true
            : remainingZoneExistsResults.removeFirst()
    }

    func calls() -> (delete: Int, verify: Int) {
        (deleteCalls, verifyCalls)
    }
}
