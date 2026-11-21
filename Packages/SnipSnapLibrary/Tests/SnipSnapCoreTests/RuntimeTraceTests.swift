import Foundation
import Synchronization
import XCTest

@testable import SnipSnapCore

final class RuntimeTraceTests: XCTestCase {
  func testTraceObserverCanDeliverExpiryBeforeReturningFromGrantedEvent() throws {
    let callback = Mutex<(@Sendable () -> Void)?>(nil)
    let delivered = DispatchSemaphore(value: 0)
    let trace = RuntimeTrace(sink: { event in
      if event.phase == .protectionGranted {
        DispatchQueue.global().async {
          callback.withLock { $0 }?()
          delivered.signal()
        }
        XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success,
          "Trace observers must not run under the expiry state lock")
      }
    }).span(.diagnostics)
    do {
      let activity = try FileAccessBackgroundActivity.begin(runner: { expire in
        callback.withLock { $0 = expire }
        return {}
      }, trace: trace)
      activity?.finish()
    } catch is CancellationError {}
  }
}
