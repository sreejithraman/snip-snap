import Foundation
import SnipSnapCore
import XCTest

final class AppDiagnosticCancellationTests: XCTestCase {
  func testTaskCocoaAndURLCancellationAreQuiet() {
    for error: any Error in [CancellationError(), CocoaError(.userCancelled), URLError(.cancelled)] {
      XCTAssertTrue(isDiagnosticCancellation(error))
    }
  }

  func testItemProviderWrappedCancellationsAreQuiet() {
    for error: any Error in [CocoaError(.userCancelled), URLError(.cancelled)] {
      let wrapped = NSError(domain: NSItemProvider.errorDomain, code: -1000,
        userInfo: [NSUnderlyingErrorKey: error])
      XCTAssertTrue(isDiagnosticCancellation(wrapped))
    }
  }

  func testUnrelatedDomainsAndTheirUnderlyingErrorsRemainFailures() {
    for code in [NSUserCancelledError, NSURLErrorCancelled] {
      XCTAssertFalse(isDiagnosticCancellation(NSError(domain: "private.domain", code: code)))
    }
    let unrelated = NSError(domain: "private.domain", code: 1,
      userInfo: [NSUnderlyingErrorKey: CocoaError(.userCancelled)])
    XCTAssertFalse(isDiagnosticCancellation(unrelated))
    let provider = NSError(domain: NSItemProvider.errorDomain, code: -1000,
      userInfo: [NSUnderlyingErrorKey: NSError(domain: "private.domain", code: NSURLErrorCancelled)])
    XCTAssertFalse(isDiagnosticCancellation(provider))
  }

  func testProviderFailureWithoutCancellationRemainsFailure() {
    XCTAssertFalse(isDiagnosticCancellation(NSError(domain: NSItemProvider.errorDomain, code: -1000)))
    let failure = NSError(domain: NSItemProvider.errorDomain, code: -1000,
      userInfo: [NSUnderlyingErrorKey: CocoaError(.fileReadNoSuchFile)])
    XCTAssertFalse(isDiagnosticCancellation(failure))
  }

  func testDeeplyNestedProviderErrorsHaveBoundedTraversal() {
    var error: any Error = CocoaError(.userCancelled)
    for _ in 0..<50 {
      error = NSError(domain: NSItemProvider.errorDomain, code: -1000,
        userInfo: [NSUnderlyingErrorKey: error])
    }
    XCTAssertFalse(isDiagnosticCancellation(error))
  }
}
