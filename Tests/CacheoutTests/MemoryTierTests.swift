import XCTest
@testable import CacheoutShared

final class MemoryTierTests: XCTestCase {

    // Note: We can't mock sysctl's hw.memsize easily without injecting a dependency,
    // so we just test the static properties and classification boundaries if they were exposed.
    // Given the current implementation of `detect()`, we just ensure it returns a valid MemoryTier.
    func testDetectReturnsValidTier() {
        let tier = MemoryTier.detect()
        // Ensure it doesn't crash and returns one of the known values
        XCTAssertTrue([.constrained, .moderate, .comfortable, .abundant, .extreme].contains(tier))
    }
}
