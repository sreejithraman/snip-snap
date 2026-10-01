import Foundation
@_spi(Maintainer) import SnipSnapCloud
import SnipSnapCore
import XCTest

final class CloudDevTransportContractTests: XCTestCase {
  func testFakeAndRealDevelopmentTransportsFollowTheSameSmallContract() async throws {
    guard Bundle.main.object(
      forInfoDictionaryKey: "SnipSnapCloudDevTransportContractEnabled"
    ) as? String == "YES" else {
      throw XCTSkip("Run through scripts/cloud-dev-transport-contract.sh.")
    }
    // The test host shares the regular Mac bundle identity. Its store override must
    // reach the hosted process so library data and diagnostic caches remain isolated.
    let isolatedStorePath = try XCTUnwrap(ProcessInfo.processInfo.environment["SNIP_SNAP_STORE_PATH"])
    XCTAssertTrue(isolatedStorePath.hasPrefix("/"))
    XCTAssertTrue(FileManager.default.fileExists(atPath:
      URL(fileURLWithPath: isolatedStorePath).deletingLastPathComponent().path))
    let diagnosticsPath = try XCTUnwrap(
      ProcessInfo.processInfo.environment["SNIP_SNAP_DIAGNOSTICS_DIRECTORY"])
    XCTAssertEqual(diagnosticsPath,
      URL(fileURLWithPath: isolatedStorePath).deletingLastPathComponent()
        .appendingPathComponent("SnipSnapDiagnostics").path)
    let diagnosticExport = try AppDiagnosticsExport.makeShareableFile()
    XCTAssertEqual(diagnosticExport.deletingLastPathComponent().path, diagnosticsPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: diagnosticExport.path))
    let identifier = try XCTUnwrap(
      Bundle.main.object(
        forInfoDictionaryKey: "SnipSnapCloudKitContainerIdentifier"
      ) as? String
    )
    do {
      try await CloudDevelopmentTransportContract.run(containerIdentifier: identifier)
    } catch {
      XCTFail(error.localizedDescription)
    }
  }
}
