# Provenance — October 10, 2026

Selected source comes from private `Hendersonajardimj/hancock-watch`, committed base `4de6440d24d57f7eabe5b2c56b8c666116c47261`, plus its preserved current working state (20 unfinished status entries). The independently verified restoration was read without changing the original. Whole-source fingerprint: `0356acec74dd6e29a5306880322515ea45953052a411793d9f27b2391e677774`.

The selected original modules are Joshua-owned agent-assisted application code; no pre-existing repository license file was present. Joshua explicitly authorized this public example. The MIT license here applies to the selected published subset, not the full private application, third-party dependencies or media-player SDK. No dependency source is vendored.

- The five Swift SyncCore modules and two existing test files come from that restoration. Changes replace personal names in fixtures/comments and the sample film title. Algorithms and assertions are retained.
- Rust `room.rs` and `db.rs` are extracted implementation. Personal test names/comments are replaced; small adapter functions at the end of `room.rs` let the synthetic harness call private registration/message handling. No room decision rules are replaced.
- New public package manifests, the synthetic library/identity/AppState adapters, Rust scenario tests, Swift JSONL demo/cross-language test, CI and docs were prepared with Codex. They are harness code, not claims of existing full-app paths.
- Recent general-chat/pagination and terminal-playback handling reflect preserved unfinished changes. Tests in this sample do not establish accepted new multi-device behavior.

## Selected original source hashes

SHA-256 before sanitization/adaptation:

- `app/Sources/SyncCore/ClockSync.swift`: `2e0ea28b671a29959470addb696d6a37e4fc9d8ada6c3eb9f9e147a1ea85b399`
- `app/Sources/SyncCore/Models.swift`: `ee599ac45104aebe1ab12efeb8423b80728eb00f7f3baf543f4ab73910a84de6`
- `app/Sources/SyncCore/SyncEngine.swift`: `f32fcb8b036b92aa355cd9b34f203ef8e74c94913c4c3ba2bdd32a1296a8be0f`
- `app/Sources/SyncCore/Formatting.swift`: `26d1e168fff3ec29679654f8d77a563b250efb2dff4d2a9ab63a7296b1178480`
- `app/Sources/SyncCore/DriftController.swift`: `be624866a41f06895d55c6a3379c5641f3b6886ec338ace559d6dc44cee75f36`
- `app/Tests/SyncCoreTests/SyncCoreTests.swift`: `0e297102c14f168aff74c0045dd48a0619b200ed4931b553f20b533eac09d91b`
- `app/Tests/SyncCoreTests/ProtocolDecodingTests.swift`: `a1216411eee18de9fe6d153e3a249bec1747eb823a73df31dfbff592e22a7da0`
- `server/src/room.rs`: `1ea0f815eee6cd60753a382d26155012e3353a9cb8a37a2ff89972035b2a1ffa`
- `server/src/db.rs`: `67c2153b9dba09822046efe1df0d3065117281adc1985b6d074233839b58d9fc`

No original private Git history, friends’ identities, network addresses, account records, movies, media-player binaries, app UI or private operational documentation is included.
