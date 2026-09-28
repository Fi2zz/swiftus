import Foundation
import SwiftusCore
import SwiftusFoundation
import Testing

/// 规格 S3 §4:SessionEvent JSON 序列化与宽容解析。
@Suite("SessionEvent JSON")
struct SessionEventCodingTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("jsonValue:nil 字段不输出,time 为 UTC 带 Z ISO8601(含小数秒)")
    func jsonValueOmitsNil() {
        let event = SessionEvent(seq: 3, type: "e", time: t0)
        guard case let .object(object) = event.jsonValue else {
            Issue.record("jsonValue 应为 object")
            return
        }
        #expect(object["seq"] == .int(3))
        #expect(object["type"] == .string("e"))
        #expect(object["data"] == nil && object["id"] == nil)
        #expect(object["sessionId"] == nil && object["parentEventId"] == nil)
        #expect(object["time"]?.stringValue?.hasSuffix("Z") == true)
    }

    @Test("jsonValue:负载凭据字段递归脱敏")
    func jsonValueRedactsSecrets() {
        let event = SessionEvent(
            seq: 0,
            type: "e",
            time: t0,
            data: .object(["api_key": .string("sk-1234567890abcdef")])
        )
        #expect(event.jsonValue["data"]?["api_key"] == .string("sk-1...cdef"))
    }

    @Test("init(jsonValue:):宽容解析缺省(seq 0、type 空串),time 解析失败退回当前时刻")
    func lenientDecoding() {
        let decoded = SessionEvent(jsonValue: .object(["type": .string("x")]))
        #expect(decoded.seq == 0 && decoded.type == "x")
        #expect(decoded.data == nil && decoded.id == nil)
        let garbage = SessionEvent(jsonValue: .object(["time": .string("not-a-date")]))
        #expect(abs(garbage.time.timeIntervalSinceNow) < 60)
    }

    @Test("jsonValue 往返:字段齐全时还原(时间到小数秒精度)")
    func roundTrip() {
        let event = SessionEvent(
            seq: 7,
            type: "e",
            time: t0,
            data: .object(["note": .string("n")]),
            id: "evt-1",
            sessionId: "s1",
            parentEventId: "evt-0"
        )
        let decoded = SessionEvent(jsonValue: event.jsonValue)
        #expect(decoded.seq == 7 && decoded.id == "evt-1")
        #expect(decoded.sessionId == "s1" && decoded.parentEventId == "evt-0")
        #expect(decoded.data == event.data)
        #expect(abs(decoded.time.timeIntervalSince(t0)) < 0.001)
    }
}
