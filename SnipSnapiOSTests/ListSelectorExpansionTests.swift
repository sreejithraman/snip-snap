import Observation
import ImageIO
import SnipSnapCore
import SnipSnapCloud
import SnipSnapPersistence
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SnipSnapiOS

final class ListSelectorExpansionTests: XCTestCase {
    func testReturningToStartingTabKeepsBarExpanded() {
        var expansion = ListSelectorExpansion()
        expansion.update(distance: 8)
        XCTAssertEqual(expansion.distance, 8)
        expansion.update(distance: 64)
        for distance: CGFloat in [24, 0, 16] {
            expansion.update(distance: distance)
            XCTAssertEqual(expansion.distance, 64)
        }
    }

    func testReleaseOrCancellationResetsExpansionForNextPan() {
        var expansion = ListSelectorExpansion()
        expansion.update(distance: 64)
        expansion.update(distance: nil)
        XCTAssertEqual(expansion.distance, 0)
        expansion.update(distance: 8)
        XCTAssertEqual(expansion.distance, 8)
    }
}
