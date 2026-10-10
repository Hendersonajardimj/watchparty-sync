import Foundation

public enum TimeFormat {
    /// `h:mm:ss` (always includes hours), e.g. 3730000 → "1:02:10", 65000 → "0:01:05".
    public static func hms(_ ms: Int64) -> String {
        let total = max(0, ms) / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }

    /// Compact form for transport labels: "4:05" under an hour, "1:02:10" otherwise.
    public static func compact(_ ms: Int64) -> String {
        let total = max(0, ms) / 1000
        if total >= 3600 { return hms(ms) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

public enum ByteFormat {
    public static func size(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }
}

/// Turns a room's `lastAction` into a short toast, e.g. "Sam paused", "Casey seeked to 1:02:10".
public enum ActionToast {
    /// Returns a toast when `room.lastAction` is new relative to `previous` and was made by someone else.
    public static func toast(for room: RoomState, previous: LastAction?, myName: String?,
                             myConnId: String? = nil) -> String? {
        guard let action = room.lastAction, action != previous else { return nil }
        // Server actions (autoWait/autoResume list the waiting names; ended has none): always shown.
        let isServerAction = ["autoWait", "autoResume", "ended"].contains(action.action)
        if !isServerAction {
            if let mine = myConnId, let theirs = action.connId {
                if mine == theirs { return nil }
            } else if let myName, action.by == myName {
                return nil
            }
        }
        return describe(action, room: room)
    }

    public static func describe(_ action: LastAction, room: RoomState) -> String {
        switch action.action {
        case "play": return "\(action.by) pressed play"
        case "pause": return "\(action.by) paused"
        case "seek": return "\(action.by) seeked to \(TimeFormat.hms(room.positionMs))"
        case "start": return "\(action.by) started \(room.movie.displayTitle)"
        case "setAutoWait": return "\(action.by) turned auto-wait \(room.autoWait ? "on" : "off")"
        case "autoWait":
            let names = room.waiting.isEmpty ? action.by : ListFormatter.localizedString(byJoining: room.waiting)
            return "Waiting for \(names)"
        case "autoResume": return "Everyone's ready"
        case "ended": return "That's the end of \(room.movie.displayTitle)"
        case "join": return "\(action.by) joined"
        case "leave": return "\(action.by) left"
        default: return "\(action.by): \(action.action)"
        }
    }
}
