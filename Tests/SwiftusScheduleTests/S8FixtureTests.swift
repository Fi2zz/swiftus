import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusSchedule
import Testing

/// 规格 S8 golden fixtures：读 JSON → 驱动 Swift 实现 → 比对 Dart 导出的期望。
@Suite("S8 golden fixtures")
struct S8FixtureTests {
    private static let fixtures = ScheduleFixtureLoader.loadAllOrEmpty()

    @Test("fixtures 已装载（spec/fixtures/s8/*.json）")
    func fixturesLoaded() {
        #expect(!Self.fixtures.isEmpty)
    }

    @Test("golden fixture", arguments: Self.fixtures)
    @ContextTreeActor
    func goldenFixture(_ fixture: ScheduleFixture) async throws {
        try await S8FixtureRunner.run(fixture)
    }
}
