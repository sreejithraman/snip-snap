import Foundation

/// Classifies expected cancellation without hiding failures from unrelated domains.
/// Item providers wrap their underlying error; only that known wrapper is unwrapped.
public func isDiagnosticCancellation(_ error: any Error) -> Bool {
  var current = error
  for _ in 0..<8 {
    if current is CancellationError { return true }
    let value = current as NSError
    if value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError { return true }
    if value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled { return true }
    guard value.domain == NSItemProvider.errorDomain,
      let underlying = value.userInfo[NSUnderlyingErrorKey] as? any Error
    else { return false }
    current = underlying
  }
  return false
}
