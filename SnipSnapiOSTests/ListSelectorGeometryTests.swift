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

final class ListSelectorGeometryTests: XCTestCase {
    func testContentSizedCentersAndNearestSelection() {
        let geometry = ListSelectorGeometry(widths: [80, 160, 100])
        XCTAssertEqual(geometry.centers, [40, 168, 306])
        XCTAssertEqual(geometry.nearestIndex(to: 103), 0)
        XCTAssertEqual(geometry.nearestIndex(to: 105), 1)
        XCTAssertEqual(geometry.nearestIndex(to: 500), 2)
    }

    func testLensWidthStaysContinuousAcrossSelectionBoundaries() {
        let geometry = ListSelectorGeometry(widths: [80, 160, 100])
        for (index, center) in geometry.centers.enumerated() {
            XCTAssertEqual(geometry.lensWidth(at: center), geometry.widths[index], accuracy: 0.001)
        }
        let boundary = (geometry.centers[0] + geometry.centers[1]) / 2
        XCTAssertNotEqual(geometry.nearestIndex(to: boundary - 0.01), geometry.nearestIndex(to: boundary + 0.01))
        XCTAssertEqual(geometry.lensWidth(at: boundary - 0.01), geometry.lensWidth(at: boundary + 0.01), accuracy: 0.1)
        XCTAssertEqual(geometry.lensWidth(at: boundary), 120, accuracy: 0.001)
        XCTAssertEqual(geometry.lensWidth(at: -100), 80)
        XCTAssertEqual(geometry.lensWidth(at: 500), 100)
        XCTAssertEqual(ListSelectorGeometry(widths: [80]).lensWidth(at: 500), 80)
        XCTAssertEqual(ListSelectorGeometry(widths: []).lensWidth(at: 0), 96)
    }

    func testPullUsesFingerDistanceAndDoesNotAddAList() {
        let geometry = ListSelectorGeometry(widths: [80])
        XCTAssertEqual(geometry.pullProgress(at: 40), 0)
        XCTAssertLessThan(geometry.pullProgress(at: 135), 1)
        XCTAssertEqual(geometry.pullProgress(at: 190), 1)
        XCTAssertEqual(geometry.pullProgress(at: 300), 1)
        XCTAssertLessThan(geometry.resisted(112), 112)
        XCTAssertEqual(geometry.nearestIndex(to: geometry.plusCenter), 0)
        XCTAssertEqual(geometry.centers.count, 1)
    }
}
