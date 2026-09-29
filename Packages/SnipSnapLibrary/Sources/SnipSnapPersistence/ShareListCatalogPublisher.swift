import Foundation
import SnipSnapCore

/// Publishes the lists the app is showing into the share picker's catalog.
///
/// This is the catalog owner in both storage modes. Assembly opens the
/// sync-mode library when an activation manifest is present, and falls back
/// to the legacy store when that manifest will not open. Either way the app
/// publishes the lists it loaded. The stores do not write Share/destinations.json:
/// the CLI reads lists from the running app, not from this file, and a second
/// writer can replace the active set. `force` rewrites a catalog an older
/// build left behind. A failed write stays unpublished so the next enqueue retries.
@MainActor
public final class ShareListCatalogPublisher {
  private let write: @Sendable ([SnipList]) async throws -> Void
  private let beforePublish: (@Sendable () async -> Void)?
  private var latest: Task<Void, Never>?
  private var published: [SnipList]?

  public init(
    write: @escaping @Sendable ([SnipList]) async throws -> Void,
    beforePublish: (@Sendable () async -> Void)? = nil
  ) {
    self.write = write
    self.beforePublish = beforePublish
  }

  public convenience init(
    imports: ShareImportStore,
    beforePublish: (@Sendable () async -> Void)? = nil
  ) {
    self.init(
      write: { try await imports.publishAvailableLists($0) },
      beforePublish: beforePublish
    )
  }

  public func enqueue(_ lists: [SnipList], force: Bool = false) {
    let previous = latest
    latest = Task {
      _ = await previous?.value
      guard force || lists != published else { return }
      await beforePublish?()
      do {
        try await write(lists)
        published = lists
      } catch {
        published = nil
      }
    }
  }

  public func flush() async {
    await latest?.value
  }
}
