# WatchParty Sync

A runnable slice of WatchParty: the actual Swift playback synchronizer, Rust room/message handler and SQLite chat persistence, with synthetic participants and a media-free reproduction harness.

[Portfolio story and recording](https://hendeaux.dev/projects/watch-party) · [Protocol](docs/PROTOCOL.md) · [Provenance](PROVENANCE.md)

## Run it

Use Rust stable for the server harness, and Swift 6 on macOS 14 or newer for the client tests/demo. No provider credentials, movie files, private network or media player are needed. Cargo downloads ordinary open-source dependencies on its first run.

```sh
cargo test --locked --manifest-path server/Cargo.toml
mkdir -p .tmp
cargo run --locked --quiet --manifest-path server/Cargo.toml > .tmp/room-trace.jsonl
swift test --package-path swift
WATCHPARTY_TRACE="$PWD/.tmp/room-trace.jsonl" swift test --package-path swift
swift run --package-path swift sync-demo .tmp/room-trace.jsonl
```

The Rust harness drives the extracted room's real handler through start/join, play, seek, user pause, buffering pause and recovery. It writes room/chat JSON frames. Swift decodes those frames with its actual wire models and demonstrates the commands it asks a player to perform. Hosted CI passes the exact Rust trace to the macOS Swift job.

## Start reading here

| Path | What to inspect |
| --- | --- |
| [SyncEngine.swift](swift/Sources/SyncCore/SyncEngine.swift) | Room state and local player state become load/play/pause/seek/rate commands. |
| [DriftController.swift](swift/Sources/SyncCore/DriftController.swift) | Small drift gets rate correction; larger drift gets a seek and cooldown. |
| [SyncCoreTests.swift](swift/Tests/SyncCoreTests/SyncCoreTests.swift) | Clock offset, drift thresholds, explicit seeks, terminal playback and buffering behavior. |
| [ProtocolDecodingTests.swift](swift/Tests/SyncCoreTests/ProtocolDecodingTests.swift) | Optional fields, unknown server types and exact client encoding. |
| [room.rs](server/src/room.rs) | Server authority, participant readiness, buffering waits and user intent. |
| [harness.rs](server/src/harness.rs) | Synthetic reproduction and focused server protocol assertions. |
| [db.rs](server/src/db.rs) | Persistent chat and pagination across isolated channels. |
| [RustTraceTests.swift](swift/Tests/SyncCoreTests/RustTraceTests.swift) | The actual Rust frames pass the Swift boundary. |

## The key distinction

A buffering pause can auto-resume when participants become ready. A user pause means someone intentionally stopped playback; readiness changes must leave it paused. The server records that distinction, while the client suppresses corrections during a seek and avoids repeatedly seeking into an ended media input. End-of-file backward seeking has its own recovery case.

The protocol uses server clock anchors rather than forcing every client to trust its wall clock. The client estimates offset from the lowest-round-trip sample, rate-corrects moderate drift and seeks larger drift. These are policy thresholds, not measured guarantees for every network or player.

## Scope and limits

This is an engineering example, not the complete Mac application, a deployed watch service or a video-streaming demo. The in-memory synthetic library and identity adapter replace private media indexing/authentication. The harness opens no network listener; JSON transport and handler behavior are reproduced in-process. The extracted WebSocket adapter remains inspectable, but live network behavior and native VLC rendering were not validated by this sample.

The original two-Mac play/pause journey was observed separately. Newer persistent/general chat and pagination come from preserved unfinished source and are covered here by synthetic tests; this is not a claim that those changes passed a new friend session. No media, friends' identities, private host configuration or original private Git history is included.

Developed with coding agents; this extraction exposes implementation, test evidence and boundaries without claiming unaided authorship. MIT license for this published subset; third-party dependencies retain their own licenses.
