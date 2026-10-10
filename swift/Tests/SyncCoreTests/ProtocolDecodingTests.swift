import Foundation
import Testing
@testable import SyncCore

/// Sample JSON taken from docs/PROTOCOL.md (comments stripped).
enum Samples {
    static let movie = """
    {"id":"a1b2c3d4e5f6","title":"Sample Film","year":2006,"quality":"2160p","container":"mkv","sizeBytes":6260778527,"addedAt":1717520000000}
    """

    static let room = """
    {
      "rev": 42,
      "movie": \(movie),
      "playing": true,
      "positionMs": 734000,
      "asOfServerTime": 1758830000000,
      "durationMs": 7020000,
      "autoWait": true,
      "waiting": ["Casey"],
      "lastAction": { "by": "Sam", "action": "seek", "at": 1758830000000, "connId": "c7" },
      "participants": [ { "connId": "c7", "userId": "sam", "name": "Sam", "state": "ready" } ],
      "startedBy": "Alex",
      "startedAt": 1758829000000
    }
    """

    static let chatMessage = """
    { "id": 118, "movieId": "a1b2c3d4e5f6", "userId": "casey", "name": "Casey",
      "text": "Synthetic hello", "movieMs": 4360000, "sentAt": 1758830000000 }
    """
}

@Suite("Protocol decoding")
struct ProtocolDecodingTests {
    private func decode(_ s: String) throws -> ServerMessage { try ServerMessage.decode(s) }

    @Test func movieWithNullables() throws {
        let m = try JSONDecoder().decode(Movie.self, from: Data(Samples.movie.utf8))
        #expect(m.id == "a1b2c3d4e5f6")
        #expect(m.sizeBytes == 6_260_778_527)
        #expect(m.displayTitle == "Sample Film (2006)")
        let bare = try JSONDecoder().decode(Movie.self, from: Data("""
        {"id":"x","title":"Home Video","year":null,"quality":null,"container":"mp4","sizeBytes":1,"addedAt":2}
        """.utf8))
        #expect(bare.year == nil && bare.quality == nil)
        #expect(bare.displayTitle == "Home Video")
    }

    @Test func movieListAndMe() throws {
        let list = try JSONDecoder().decode(MovieList.self, from: Data("{\"movies\":[\(Samples.movie)]}".utf8))
        #expect(list.movies.count == 1)
        let me = try JSONDecoder().decode(Me.self, from: Data(#"{"userId":"alex","name":"Alex"}"#.utf8))
        #expect(me.name == "Alex")
        let h = try JSONDecoder().decode(Health.self, from: Data(#"{"ok":true,"version":"0.1.0"}"#.utf8))
        #expect(h.ok && h.version == "0.1.0")
        let noRoom = try JSONDecoder().decode(RoomState?.self, from: Data("null".utf8))
        #expect(noRoom == nil)
    }

    @Test func welcomeWithRoom() throws {
        let msg = try decode("""
        {"type":"welcome","you":{"userId":"alex","name":"Alex","connId":"c3"},"serverTime":1758830000123,"room":\(Samples.room)}
        """)
        guard case .welcome(let you, let serverTime, let room) = msg else { Issue.record("not welcome"); return }
        #expect(you == You(userId: "alex", name: "Alex", connId: "c3"))
        #expect(serverTime == 1_758_830_000_123)
        let r = try #require(room)
        #expect(r.rev == 42)
        #expect(r.movie.quality == "2160p")
        #expect(r.playing)
        #expect(r.positionMs == 734_000)
        #expect(r.durationMs == 7_020_000)
        #expect(r.waiting == ["Casey"])
        #expect(r.lastAction == LastAction(by: "Sam", action: "seek", at: 1_758_830_000_000, connId: "c7"))
        #expect(r.participants == [Participant(connId: "c7", userId: "sam", name: "Sam", state: "ready")])
        #expect(r.startedBy == "Alex")
        #expect(r.isJoined(connId: "c7"))
        #expect(!r.isJoined(connId: "c3"))
    }

    @Test func welcomeWithoutRoom() throws {
        let msg = try decode(#"{"type":"welcome","you":{"userId":"casey","name":"Casey","connId":"c1"},"serverTime":5,"room":null}"#)
        #expect(msg == .welcome(you: You(userId: "casey", name: "Casey", connId: "c1"), serverTime: 5, room: nil))
    }

    @Test func pong() throws {
        #expect(try decode(#"{"type":"pong","clientTime":100,"serverTime":250}"#) == .pong(clientTime: 100, serverTime: 250))
    }

    @Test func roomAndNullRoom() throws {
        guard case .room(let r?) = try decode("{\"type\":\"room\",\"room\":\(Samples.room)}") else {
            Issue.record("expected room"); return
        }
        #expect(r.autoWait)
        #expect(try decode(#"{"type":"room","room":null}"#) == .room(nil))
    }

    @Test func roomWithNullDurationAndLastAction() throws {
        let json = Samples.room
            .replacingOccurrences(of: "\"durationMs\": 7020000", with: "\"durationMs\": null")
            .replacingOccurrences(of: #"{ "by": "Sam", "action": "seek", "at": 1758830000000, "connId": "c7" }"#, with: "null")
        guard case .room(let r?) = try decode("{\"type\":\"room\",\"room\":\(json)}") else {
            Issue.record("expected room"); return
        }
        #expect(r.durationMs == nil)
        #expect(r.lastAction == nil)
    }

    @Test func chatHistory() throws {
        let msg = try decode("{\"type\":\"chatHistory\",\"movieId\":\"a1b2c3d4e5f6\",\"messages\":[\(Samples.chatMessage)]}")
        guard case .chatHistory(let movieId, let messages) = msg else { Issue.record("not chatHistory"); return }
        #expect(movieId == "a1b2c3d4e5f6")
        #expect(messages.count == 1)
        #expect(messages[0].movieMs == 4_360_000)
    }

    @Test func chatWithAndWithoutMovieMs() throws {
        guard case .chat(let m) = try decode("{\"type\":\"chat\",\"message\":\(Samples.chatMessage)}") else {
            Issue.record("not chat"); return
        }
        #expect(m == ChatMessage(id: 118, movieId: "a1b2c3d4e5f6", userId: "casey", name: "Casey",
                                 text: "Synthetic hello", movieMs: 4_360_000, sentAt: 1_758_830_000_000))
        #expect(m.body == .text("Synthetic hello"))
        let noMs = Samples.chatMessage.replacingOccurrences(of: "4360000", with: "null")
        guard case .chat(let m2) = try decode("{\"type\":\"chat\",\"message\":\(noMs)}") else {
            Issue.record("not chat"); return
        }
        #expect(m2.movieMs == nil)
    }

    @Test func paginatedChatAndGeneralBroadcast() throws {
        let page = try decode(#"{"type":"chatPage","movieId":"general","messages":[],"hasMore":true,"before":42}"#)
        #expect(page == .chatPage(movieId: "general", messages: [], hasMore: true, before: 42))
        let broadcast = try decode("{\"type\":\"generalChat\",\"message\":\(Samples.chatMessage)}")
        guard case .chat = broadcast else { Issue.record("not chat"); return }
    }

    @Test func error() throws {
        #expect(try decode(#"{"type":"error","message":"not joined"}"#) == .error("not joined"))
    }

    @Test func unknownTypeDoesNotThrow() throws {
        #expect(try decode(#"{"type":"somethingNew","x":1}"#) == .unknown(type: "somethingNew"))
    }
}

@Suite("Client message encoding")
struct ClientEncodingTests {
    private func json(_ m: ClientMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(m)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func encodesEveryType() throws {
        #expect(try json(.ping(clientTime: 7)) as NSDictionary == ["type": "ping", "clientTime": 7])
        #expect(try json(.start(movieId: "abc")) as NSDictionary == ["type": "start", "movieId": "abc"])
        #expect(try json(.join) as NSDictionary == ["type": "join"])
        #expect(try json(.leave) as NSDictionary == ["type": "leave"])
        #expect(try json(.play(positionMs: 1)) as NSDictionary == ["type": "play", "positionMs": 1])
        #expect(try json(.pause(positionMs: 2)) as NSDictionary == ["type": "pause", "positionMs": 2])
        #expect(try json(.seek(positionMs: 3)) as NSDictionary == ["type": "seek", "positionMs": 3])
        #expect(try json(.status(state: .buffering, positionMs: 4, durationMs: 9)) as NSDictionary
                == ["type": "status", "state": "buffering", "positionMs": 4, "durationMs": 9])
        #expect(try json(.status(state: .ready, positionMs: 4, durationMs: nil)) as NSDictionary
                == ["type": "status", "state": "ready", "positionMs": 4])
        #expect(try json(.chat(text: "hi", movieMs: 5)) as NSDictionary == ["type": "chat", "text": "hi", "movieMs": 5])
        #expect(try json(.chat(text: "hi", movieMs: nil)) as NSDictionary == ["type": "chat", "text": "hi", "movieMs": NSNull()])
        #expect(try json(.generalChat(text: "hello")) as NSDictionary == ["type": "generalChat", "text": "hello"])
        #expect(try json(.chatPage(movieId: "general", before: 42)) as NSDictionary == ["type": "chatPage", "movieId": "general", "before": 42])
        #expect(try json(.setAutoWait(enabled: false)) as NSDictionary == ["type": "setAutoWait", "enabled": false])
    }
}
