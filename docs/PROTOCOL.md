# Reproduced room protocol

All JSON keys are camelCase and positions/times are integer milliseconds. The actual handler and Swift models are the source of truth; this is the bounded sample's guide rather than the private deployment runbook.

The synthetic identities Alex and Casey register as connections `c1` and `c2`. Starting `synthetic-movie` creates a paused room and joins the initiator; the second connection joins separately. Participants begin buffering and report ready. Only joined connections can control playback or send movie chat. General chat does not require joining a movie.

Messages include `start`, `join`, `leave`, `play`, `pause`, `seek`, `status`, `setAutoWait`, `chat`, `generalChat`, and `chatPage`; `ping` echoes a client timestamp with server time. `status` carries readiness and optional duration; its reported position is currently accepted but not used by the server. Play/pause/seek use a position and update the server anchor. Seek preserves current play intent.

Room output includes revision, movie, playing, position, server anchor, optional duration, auto-wait settings, waiting participants, last action and participants. Effective client position is the anchor plus elapsed server time when playing, clamped to duration. A new explicit seek can be honored inside the normal drift band; revision bumps alone do not create a new seek.

Buffering above the threshold can freeze the room with `lastAction.action = autoWait`. When everyone is ready, only that waiting pause resumes with `autoResume`. An intentional pause clears the auto-resume condition. The example uses zero waiting threshold so it is reproducible without sleeping; the original application uses its configured threshold. Finishing known-duration playback produces `ended` rather than resuming.

Movie chat requires joining. General chat is stored under a separate `general` channel. Chat text must be nonblank and at most 2,000 characters. `chatPage` returns up to 200 messages, a `hasMore` flag and cursor. The existing SQLite test verifies persistence after reopen and that pagination does not mix movie/general channels.

The in-process harness exercises actual protocol handling and emits JSONL for the real Swift decoder. It does not exercise a WebSocket socket, production authentication, streaming ranges, real media timing or multi-device networking.
