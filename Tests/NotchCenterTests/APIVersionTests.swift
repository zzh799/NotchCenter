import XCTest
import NotchCenterKit

final class APIVersionTests: XCTestCase {
    // MARK: SemanticVersion

    func testParsesVersionsWithOptionalPatchAndPrefix() {
        XCTAssertEqual(SemanticVersion(string: "1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion(string: "1.2"), SemanticVersion(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(SemanticVersion(string: "1"), SemanticVersion(major: 1, minor: 0, patch: 0))
        XCTAssertEqual(SemanticVersion(string: "v2.0.0"), SemanticVersion(major: 2, minor: 0, patch: 0))
        XCTAssertEqual(SemanticVersion(string: " 3.4.5 "), SemanticVersion(major: 3, minor: 4, patch: 5))
    }

    func testRejectsInvalidVersions() {
        XCTAssertNil(SemanticVersion(string: ""))
        XCTAssertNil(SemanticVersion(string: "abc"))
        XCTAssertNil(SemanticVersion(string: "1.2.3.4"))
        XCTAssertNil(SemanticVersion(string: "1.x"))
        XCTAssertNil(SemanticVersion(string: "1..2"))
    }

    func testVersionOrdering() {
        XCTAssertLessThan(SemanticVersion(major: 1, minor: 9, patch: 9), SemanticVersion(major: 2, minor: 0))
        XCTAssertLessThan(SemanticVersion(major: 1, minor: 1), SemanticVersion(major: 1, minor: 2))
        XCTAssertLessThan(SemanticVersion(major: 1, minor: 2, patch: 0), SemanticVersion(major: 1, minor: 2, patch: 1))
    }

    // MARK: APIVersionRange（文档 §9.1）

    func testHalfOpenRangeIncludesLowerExcludesUpper() {
        let range = try! XCTUnwrap(APIVersionRange(string: "1.0..<2.0"))
        XCTAssertTrue(range.contains(SemanticVersion(major: 1, minor: 0, patch: 0)))
        XCTAssertTrue(range.contains(SemanticVersion(major: 1, minor: 9, patch: 99)))
        XCTAssertFalse(range.contains(SemanticVersion(major: 2, minor: 0, patch: 0)))
        XCTAssertFalse(range.contains(SemanticVersion(major: 0, minor: 9, patch: 0)))
    }

    func testClosedRangeIncludesBothBounds() {
        let range = try! XCTUnwrap(APIVersionRange(string: "1.0...1.2"))
        XCTAssertTrue(range.contains(SemanticVersion(major: 1, minor: 0)))
        XCTAssertTrue(range.contains(SemanticVersion(major: 1, minor: 2)))
        XCTAssertFalse(range.contains(SemanticVersion(major: 1, minor: 3)))
    }

    func testExactRangeMatchesOnlyThatVersion() {
        let range = try! XCTUnwrap(APIVersionRange(string: "1.2.3"))
        XCTAssertTrue(range.contains(SemanticVersion(major: 1, minor: 2, patch: 3)))
        XCTAssertFalse(range.contains(SemanticVersion(major: 1, minor: 2, patch: 4)))
    }

    func testShortBoundsArePaddedWithZeros() {
        let range = try! XCTUnwrap(APIVersionRange(string: "1..<2"))
        XCTAssertTrue(range.contains(SemanticVersion(major: 1, minor: 5)))
        XCTAssertFalse(range.contains(SemanticVersion(major: 2, minor: 0)))
    }

    func testRejectsMalformedRanges() {
        XCTAssertNil(APIVersionRange(string: ""))
        XCTAssertNil(APIVersionRange(string: "2.0..<1.0"))
        XCTAssertNil(APIVersionRange(string: "abc..<def"))
        // 精确版本是合法范围（文档 §9.1 语义化版本范围允许精确匹配）。
        XCTAssertNotNil(APIVersionRange(string: "1.0"))
        // 缺下界/上界
        XCTAssertNil(APIVersionRange(string: "2.0..<x"))
    }

    func testCurrentVersionFallsInsideOfficialPluginsRange() {
        let officialRange = try! XCTUnwrap(APIVersionRange(string: "1.0..<2.0"))
        XCTAssertTrue(officialRange.contains(NotchCenterKitAPI.currentVersion))
    }
}