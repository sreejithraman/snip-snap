import Foundation
import SnipSnapCore
import XCTest

final class SnipCLIApplicationResultRevisionTests: XCTestCase {
  func testExplicitOwnerRevisionSurvivesReceiptEncoding() throws {
    let result = SnipCLIApplicationResult(
      values: ["bytes": "123", "content-revision": "owner-token"], revision: "owner-token"
    )
    XCTAssertEqual(result.revision, "owner-token")
    XCTAssertEqual(result.values["bytes"], "123")
    XCTAssertEqual(
      try JSONDecoder().decode(SnipCLIApplicationResult.self, from: JSONEncoder().encode(result)),
      result
    )
    XCTAssertNotEqual(SnipCLIApplicationResult(values: result.values).revision, result.revision)
  }
}
