//! A credential-free reproduction using the extracted server's actual message handler.
use crate::{AppState, db::Db, library::Library, room::{Hub, harness_register, harness_handle}};
use serde_json::{json, Value};
use std::{path::Path, sync::{Mutex, RwLock}, time::Duration};

fn state() -> AppState {
    AppState { db: Db::open(Path::new(":memory:")).unwrap(), library: RwLock::new(Library::synthetic()), hub: Mutex::new(Hub::new(Duration::from_secs(15), Duration::ZERO)) }
}
fn frame(hub: &Hub) -> Value { json!({"type":"room", "room":hub.room_json()}) }
pub fn scenario() -> Result<Vec<Value>, String> {
    let state=state(); let mut hub=state.hub.lock().unwrap();
    let alex=harness_register(&mut hub,"Alex"); let casey=harness_register(&mut hub,"Casey");
    let mut frames=Vec::new();
    let actions=[
        (&alex,json!({"type":"start","movieId":"synthetic-movie"})),
        (&casey,json!({"type":"join"})),
        (&alex,json!({"type":"status","state":"ready","durationMs":120000})),
        (&casey,json!({"type":"status","state":"ready"})),
        (&alex,json!({"type":"play","positionMs":10000})),
        (&alex,json!({"type":"seek","positionMs":20000})),
        (&alex,json!({"type":"pause","positionMs":25000})),
        (&alex,json!({"type":"play","positionMs":30000})),
        (&casey,json!({"type":"status","state":"buffering"})),
        (&casey,json!({"type":"status","state":"ready"})),
        (&alex,json!({"type":"pause","positionMs":40000})),
        (&casey,json!({"type":"status","state":"buffering"})),
        (&casey,json!({"type":"status","state":"ready"})),
    ];
    for (conn,action) in actions { harness_handle(&mut hub,&state,conn,&action.to_string())?; frames.push(frame(&hub)); }
    harness_handle(&mut hub,&state,&alex,&json!({"type":"generalChat","text":"Synthetic hello"}).to_string())?;
    frames.push(json!({"type":"chatPage","movieId":"general","messages":state.db.history("general",200).unwrap(),"hasMore":false,"before":null}));
    Ok(frames)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn user_pause_stays_paused_after_a_buffering_client_recovers() {
        let frames=scenario().unwrap(); let rooms:Vec<_>=frames.iter().filter_map(|f|f.get("room")).collect();
        let final_room=rooms.last().unwrap();
        assert_eq!(final_room["playing"],false); assert_eq!(final_room["positionMs"],40000);
        assert_eq!(final_room["lastAction"]["action"],"pause");
    }
    #[test] fn buffering_pause_resumes_but_explicit_seek_is_preserved() {
        let frames=scenario().unwrap();
        let wait=frames.iter().find(|f| f["room"]["lastAction"]["action"]=="autoWait").unwrap();
        assert_eq!(wait["room"]["playing"],false); assert_eq!(wait["room"]["waiting"],json!(["Casey"]));
        let resume=frames.iter().find(|f| f["room"]["lastAction"]["action"]=="autoResume").unwrap();
        assert_eq!(resume["room"]["playing"],true);
        let seek=frames.iter().find(|f| f["room"]["lastAction"]["action"]=="seek").unwrap();
        assert_eq!(seek["room"]["positionMs"],20000); assert_eq!(seek["room"]["playing"],true);
    }
    #[test] fn unjoined_controls_bad_json_and_unknown_movies_are_rejected() {
        let state=state();let mut hub=state.hub.lock().unwrap();let conn=harness_register(&mut hub,"Alex");
        assert!(harness_handle(&mut hub,&state,&conn,"not json").is_err());
        assert!(harness_handle(&mut hub,&state,&conn,r#"{"type":"play","positionMs":0}"#).unwrap_err().contains("join"));
        assert!(harness_handle(&mut hub,&state,&conn,r#"{"type":"start","movieId":"missing"}"#).unwrap_err().contains("unknown movie"));
    }
    #[test] fn new_general_chat_uses_persistence_without_requiring_a_room() {
        let state=state();let mut hub=state.hub.lock().unwrap();let conn=harness_register(&mut hub,"Alex");
        harness_handle(&mut hub,&state,&conn,r#"{"type":"generalChat","text":" Hello "}"#).unwrap();
        assert_eq!(state.db.history("general",200).unwrap()[0].text,"Hello");
        assert!(harness_handle(&mut hub,&state,&conn,r#"{"type":"generalChat","text":" "}"#).is_err());
        assert!(harness_handle(&mut hub,&state,&conn,r#"{"type":"chatPage","movieId":"missing"}"#).is_err());
    }
}
