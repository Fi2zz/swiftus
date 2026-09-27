import Foundation
import SwiftusCore
import Testing
@testable import SwiftusLLM

/// 规格 S10 §6:SseFolder 的确定性字节级用例(不触网络)。
@Suite("SseFolder SSE 折叠器")
struct SseFolderTests {
    /// 把原始串逐字节(最坏切块)喂入折叠器,收集产出的帧序列。
    private func collect(_ raw: String) async throws -> (frames: [String], terminated: Bool) {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let folder = SseFolder()
        for byte in raw.utf8 {
            folder.consume(byte, continuation: continuation)
        }
        folder.finish(continuation: continuation)
        continuation.finish()
        var frames: [String] = []
        for try await frame in stream {
            frames.append(frame)
        }
        return (frames, folder.terminated)
    }

    @Test("空行成帧、注释与非 data 字段忽略、[DONE] 终止且之后忽略")
    func folding() async throws {
        let raw = ": 注释\nevent: message\nid: 1\ndata: {\"a\":1}\n\ndata: {\"b\":2}\n\ndata: [DONE]\ndata: 之后\n\n"
        let (frames, terminated) = try await collect(raw)
        #expect(frames == ["{\"a\":1}", "{\"b\":2}"])
        #expect(terminated)
    }

    @Test("多行 data 以换行拼接成一帧")
    func multilineData() async throws {
        let (frames, _) = try await collect("data: {\"a\"\ndata: :1}\n\n")
        #expect(frames == ["{\"a\"\n:1}"])
    }

    @Test("多字节 UTF-8 逐字节喂入不破碎")
    func multibyteUtf8() async throws {
        let (frames, _) = try await collect("data: 你好\n\n")
        #expect(frames == ["你好"])
    }

    @Test("CRLF 行尾与流尾无换行的残留行")
    func crlfAndTail() async throws {
        let (frames, _) = try await collect("data: x\r\n\r\ndata: 尾部")
        #expect(frames == ["x", "尾部"])
    }

    @Test("空输入无帧")
    func empty() async throws {
        let (frames, terminated) = try await collect("")
        #expect(frames.isEmpty)
        #expect(!terminated)
    }
}
