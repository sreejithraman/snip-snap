import Foundation
import SnipSnapCore

public struct LocalSnipLibraryOpenResult: Sendable {
  public let library: any SnipLibrary
  public let errorMessage: String?

  init(library: any SnipLibrary, errorMessage: String? = nil) {
    self.library = library
    self.errorMessage = errorMessage
  }
}

public struct LocalSnipStorePaths: Equatable, Sendable {
  public let rootDirectory: URL
  public let swiftDataStoreURL: URL

  public init(rootDirectory: URL) {
    self.rootDirectory = rootDirectory
    swiftDataStoreURL = rootDirectory
      .appendingPathComponent("Local", isDirectory: true)
      .appendingPathComponent("snips.store", isDirectory: false)
  }

  public init(storeURL: URL) {
    self.init(rootDirectory: storeURL.deletingLastPathComponent().deletingLastPathComponent())
  }
}

/// Opens the Mac local SwiftData store. JSON is import and export only.
public enum MacLocalSnipLibraryBootstrap {
  public static func open(
    storeURL: URL = SwiftDataSnipLibrary.defaultStoreURL()
  ) -> LocalSnipLibraryOpenResult {
    do {
      return LocalSnipLibraryOpenResult(
        library: try SwiftDataSnipLibrary(storeURL: storeURL)
      )
    } catch {
      return LocalSnipLibraryOpenResult(
        library: SwiftDataSnipLibrary.unavailable(storeURL: storeURL),
        errorMessage: String(
          localized: "Snip Snap could not open its SwiftData store, so it cannot save new snips.",
          bundle: .main
        )
      )
    }
  }
}
