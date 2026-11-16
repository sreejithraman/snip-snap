import Foundation
import Security
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
    defer { AppDiagnosticsExport.removeShareableFile(diagnosticExport) }
    XCTAssertEqual(diagnosticExport.lastPathComponent, "Snip-Snap-Diagnostics.txt")
    let stagingDirectory = diagnosticExport.deletingLastPathComponent()
    XCTAssertTrue(stagingDirectory.lastPathComponent.hasPrefix("share-"))
    XCTAssertEqual(stagingDirectory.deletingLastPathComponent().path, diagnosticsPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: diagnosticExport.path))
    let identifier = try XCTUnwrap(
      Bundle.main.object(
        forInfoDictionaryKey: "SnipSnapCloudKitContainerIdentifier"
      ) as? String
    )
    // Inspect only the running host's entitlement values; never log signing/account data.
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess else {
      return XCTFail("Could not identify the signed test host.")
    }
    var signing: CFDictionary?
    let runningCode = try XCTUnwrap(code)
    var staticCode: SecStaticCode?
    guard SecCodeCheckValidity(runningCode, [], nil) == errSecSuccess,
      SecCodeCopyStaticCode(runningCode, [], &staticCode) == errSecSuccess,
      let staticCode,
      SecCodeCopySigningInformation(staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess else {
      return XCTFail("The test host requires valid Development signing.")
    }
    let information = try XCTUnwrap(signing) as NSDictionary
    let entitlements = try XCTUnwrap(information[kSecCodeInfoEntitlementsDict] as? NSDictionary)
    guard entitlements["com.apple.developer.icloud-container-environment"] as? String == "Development",
      (entitlements["com.apple.developer.icloud-container-identifiers"] as? [String])?.contains(identifier) == true
    else { return XCTFail("The running host requires the signed Development container entitlement.") }
    let environment = ProcessInfo.processInfo.environment
    let evidencePath = try XCTUnwrap(environment["SNIP_SNAP_CONTRACT_EVIDENCE_DIRECTORY"])
    let source = try XCTUnwrap(environment["SNIP_SNAP_CONTRACT_SOURCE_REVISION"])
    let harness = try XCTUnwrap(environment["SNIP_SNAP_CONTRACT_HARNESS_REVISION"])
    let started = try XCTUnwrap(environment["SNIP_SNAP_CONTRACT_STARTED_AT"].flatMap(TimeInterval.init))
    guard evidencePath.hasPrefix("/"), evidencePath == URL(fileURLWithPath: isolatedStorePath)
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("atomic-proof").path
    else { return XCTFail("Contract evidence must share the isolated runner directory.") }
    do {
      try await CloudDevelopmentTransportContract.run(containerIdentifier: identifier,
        evidenceDirectory: URL(fileURLWithPath: evidencePath), sourceRevision: source,
        harnessRevision: harness, sessionStartedAt: Date(timeIntervalSince1970: started))
    } catch {
      XCTFail(error.localizedDescription)
    }
  }
}
