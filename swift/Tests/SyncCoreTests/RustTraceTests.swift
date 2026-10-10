import Foundation
import Testing
@testable import SyncCore
@Suite("Actual Rust room trace")
struct RustTraceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WATCHPARTY_TRACE"] != nil))
    func wireFramesAndClientIntent() throws {
        let path = try #require(ProcessInfo.processInfo.environment["WATCHPARTY_TRACE"])
        let data = try String(contentsOfFile: path, encoding: .utf8)
        var rooms: [RoomState] = []; var chat = false
        for line in data.split(separator: "\n") {
            let message = try ServerMessage.decode(String(line))
            if case .room(let room?) = message { rooms.append(room) }
            if case .chatPage(let movieId, let messages, _, _) = message {
                #expect(movieId == "general"); #expect(messages.first?.text == "Synthetic hello"); chat = true
            }
        }
        #expect(chat); #expect(rooms.count == 13)
        let wait = try #require(rooms.first { $0.lastAction?.action == "autoWait" })
        #expect(!wait.playing); #expect(wait.waiting == ["Casey"])
        let resume = try #require(rooms.first { $0.lastAction?.action == "autoResume" })
        #expect(resume.playing)
        let final = try #require(rooms.last)
        #expect(!final.playing); #expect(final.positionMs == 40_000); #expect(final.lastAction?.action == "pause")
        var engine = SyncEngine()
        let commands = engine.reconcile(room: final, joined: true, local: LocalPlayerState(loadedMovieId: final.movie.id, isReady: true, isPlaying: true, positionMs: 40_000), serverNow: final.asOfServerTime, now: final.asOfServerTime)
        #expect(commands.contains(.pause))
    }
}
