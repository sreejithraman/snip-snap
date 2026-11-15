import Foundation

/// Limits how long one direct CloudKit call may run. CloudKit ends a call after `idle` without
/// data or after its kind's total.
package struct CloudKitCallBound: Sendable {
  package enum Kind: Sendable {
    /// Account checks, small records, and zone changes.
    case small
    /// Any call that moves a file, such as an attachment or clipboard asset.
    case transfer
  }

  package let idle: Duration
  package let smallTotal: Duration
  package let transferTotal: Duration
  package let backstopMargin: Duration

  package static let standard = CloudKitCallBound(
    idle: .seconds(30),
    smallTotal: .seconds(60),
    transferTotal: .seconds(10 * 60),
    backstopMargin: .seconds(15)
  )

  package init(
    idle: Duration,
    smallTotal: Duration,
    transferTotal: Duration,
    backstopMargin: Duration
  ) {
    self.idle = idle
    self.smallTotal = smallTotal
    self.transferTotal = transferTotal
    self.backstopMargin = backstopMargin
  }
}
