import XCTest
@testable import CacheoutShared

final class PressureTierTests: XCTestCase {

    func testValidConfigValues() {
        let expected: Set<String> = ["normal", "elevated", "warning", "critical", "warn"]
        XCTAssertEqual(PressureTier.validConfigValues, expected)
    }

    func testFromConfigValue() {
        XCTAssertEqual(PressureTier.fromConfigValue("normal"), .normal)
        XCTAssertEqual(PressureTier.fromConfigValue("elevated"), .elevated)
        XCTAssertEqual(PressureTier.fromConfigValue("warning"), .warning)
        XCTAssertEqual(PressureTier.fromConfigValue("warn"), .warning)
        XCTAssertEqual(PressureTier.fromConfigValue("critical"), .critical)

        // Invalid
        XCTAssertNil(PressureTier.fromConfigValue("unknown"))
        XCTAssertNil(PressureTier.fromConfigValue("WARN")) // case-sensitive
    }

    func testFromPressureLevelAndAvailableMB() {
        // Critical conditions
        XCTAssertEqual(PressureTier.from(pressureLevel: 4, availableMB: 2000), .critical)
        XCTAssertEqual(PressureTier.from(pressureLevel: 0, availableMB: 500), .critical)

        // Warning conditions
        XCTAssertEqual(PressureTier.from(pressureLevel: 2, availableMB: 2000), .warning)
        XCTAssertEqual(PressureTier.from(pressureLevel: 0, availableMB: 1000), .warning)

        // Elevated conditions
        XCTAssertEqual(PressureTier.from(pressureLevel: 1, availableMB: 5000), .elevated)
        XCTAssertEqual(PressureTier.from(pressureLevel: 0, availableMB: 3000), .elevated)

        // Normal conditions
        XCTAssertEqual(PressureTier.from(pressureLevel: 0, availableMB: 8000), .normal)
        XCTAssertEqual(PressureTier.from(pressureLevel: 0, availableMB: 4001), .normal)
    }
}
