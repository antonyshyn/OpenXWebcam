import XCTest
@testable import CameraEngine

final class RetryPolicyTests: XCTestCase {
    func testBackoffSequence() {
        var policy = RetryPolicy(maxAttempts: 5, baseDelay: 0.3, maxDelay: 2.0)
        XCTAssertEqual(policy.nextDelay(), 0.3)
        XCTAssertEqual(policy.nextDelay(), 0.6)
        XCTAssertEqual(policy.nextDelay(), 1.2)
        XCTAssertEqual(policy.nextDelay(), 2.0)
        XCTAssertEqual(policy.nextDelay(), 2.0)
        XCTAssertNil(policy.nextDelay())
    }

    func testReset() {
        var policy = RetryPolicy(maxAttempts: 1)
        XCTAssertNotNil(policy.nextDelay())
        XCTAssertNil(policy.nextDelay())
        policy.reset()
        XCTAssertNotNil(policy.nextDelay())
    }
}
