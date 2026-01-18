@testable import Muesli
import XCTest

final class TimeFormattingTests: XCTestCase {
    func testStandardStyleUnderOneHour() {
        XCTAssertEqual(TimeFormatting.formatTimestamp(10.5, style: .standard), "00:10")
        XCTAssertEqual(TimeFormatting.formatTimestamp(65.0, style: .standard), "01:05")
        XCTAssertEqual(TimeFormatting.formatTimestamp(599.0, style: .standard), "09:59")
    }
    
    func testStandardStyleWithHours() {
        XCTAssertEqual(TimeFormatting.formatTimestamp(3661.0, style: .standard), "1:01:01")
        XCTAssertEqual(TimeFormatting.formatTimestamp(7384.0, style: .standard), "2:03:04")
    }
    
    func testCompactStyleUnderOneHour() {
        XCTAssertEqual(TimeFormatting.formatTimestamp(10.5, style: .compact), "0:10")
        XCTAssertEqual(TimeFormatting.formatTimestamp(65.0, style: .compact), "1:05")
    }
    
    func testCompactStyleWithHours() {
        XCTAssertEqual(TimeFormatting.formatTimestamp(3661.0, style: .compact), "1:01:01")
    }
    
    func testShortOnlyStyle() {
        XCTAssertEqual(TimeFormatting.formatTimestamp(10.5, style: .shortOnly), "00:10")
        XCTAssertEqual(TimeFormatting.formatTimestamp(3661.0, style: .shortOnly), "61:01")
    }
    
    func testDefaultStyleIsStandard() {
        XCTAssertEqual(
            TimeFormatting.formatTimestamp(10.5),
            TimeFormatting.formatTimestamp(10.5, style: .standard)
        )
    }
}
