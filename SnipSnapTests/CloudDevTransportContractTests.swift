import Foundation
@_spi(Maintainer) import SnipSnapCloud
import XCTest

final class CloudDevTransportContractTests: XCTestCase {
  func testFakeAndRealDevelopmentTransportsFollowTheSameSmallContract() async throws {
    guard Bundle.main.object(
      forInfoDictionaryKey: "SnipSnapCloudDevTransportContractEnabled"
    ) as? String == "YES" else {
      throw XCTSkip("Run through scripts/cloud-dev-transport-contract.sh.")
    }
    let identifier = try XCTUnwrap(
      Bundle.main.object(
        forInfoDictionaryKey: "SnipSnapCloudKitContainerIdentifier"
      ) as? String
    )
    try await CloudDevelopmentTransportContract.run(
      containerIdentifier: identifier
    )
  }
}
