@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class SwallowTest: XCTestCase {
    func testParseSwallow() {
        let result = parseConfig(
            """
            [swallow]
                enabled = true
                exceptions = ['org.videolan.vlc']
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.swallow, SwallowConfig(enabled: true, terminals: [], exceptions: ["org.videolan.vlc"]))
        assertEquals(parseConfig("").config.swallow.enabled, false)
    }

    func testAncestorPids() {
        let ancestors = ancestorPids(of: getpid())
        XCTAssertTrue(ancestors.contains(getppid()))
        XCTAssertFalse(ancestors.contains(getpid()))
        XCTAssertFalse(ancestors.contains(1)) // stops before launchd
    }
}
