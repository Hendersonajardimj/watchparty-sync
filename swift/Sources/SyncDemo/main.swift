import Foundation
import SyncCore
guard CommandLine.arguments.count == 2 else { fatalError("Pass a Rust JSONL trace path.") }
let input = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
var engine = SyncEngine()
var local = LocalPlayerState.empty
for line in input.split(separator: "\n") {
    let message = try ServerMessage.decode(String(line))
    guard case .room(let room?) = message else { continue }
    let commands = engine.reconcile(room: room, joined: true, local: local, serverNow: room.asOfServerTime, now: room.asOfServerTime)
    print("\(room.lastAction?.action ?? "state") at \(room.positionMs)ms -> \(commands)")
    local = LocalPlayerState(loadedMovieId: room.movie.id, isReady: true, isPlaying: room.playing, positionMs: room.positionMs)
}
