//! The single watch room: WebSocket protocol, sync state, auto-wait, grace close, chat.

use crate::db::ChatMessage;
use crate::identity::Identity;
use crate::library::Movie;
use crate::AppState;
use axum::extract::ws::{Message, WebSocket};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc::{unbounded_channel, UnboundedSender};

const CHAT_HISTORY: usize = 200;
const CHAT_MAX_CHARS: usize = 2000;
const IDLE_TIMEOUT: Duration = Duration::from_secs(45);
const PING_EVERY: Duration = Duration::from_secs(15);

pub fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PState {
    Ready,
    Buffering,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LastAction {
    pub by: String,
    pub action: String,
    pub at: i64,
    /// Connection that caused it; absent for server actions (autoWait, autoResume, ended).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub conn_id: Option<String>,
}

struct Participant {
    conn_id: String,
    user_id: String,
    name: String,
    state: PState,
    buffering_since: Instant,
}

struct Room {
    movie: Movie,
    playing: bool,
    position_ms: i64,
    as_of: i64,
    duration_ms: Option<i64>,
    auto_wait: bool,
    waiting: Vec<String>,
    paused_by_wait: bool,
    last_action: Option<LastAction>,
    participants: Vec<Participant>,
    started_by: String,
    started_at: i64,
    rev: u64,
    empty_since: Option<Instant>,
}

impl Room {
    fn effective_position(&self, now: i64) -> i64 {
        if self.playing {
            self.position_ms + (now - self.as_of).max(0)
        } else {
            self.position_ms
        }
    }

    fn to_json(&self) -> Value {
        json!({
            "rev": self.rev,
            "movie": self.movie,
            "playing": self.playing,
            "positionMs": self.position_ms,
            "asOfServerTime": self.as_of,
            "durationMs": self.duration_ms,
            "autoWait": self.auto_wait,
            "waiting": self.waiting,
            "lastAction": self.last_action,
            "participants": self.participants.iter().map(|p| json!({
                "connId": p.conn_id,
                "userId": p.user_id,
                "name": p.name,
                "state": p.state,
            })).collect::<Vec<_>>(),
            "startedBy": self.started_by,
            "startedAt": self.started_at,
        })
    }

    fn anchor(&mut self, position_ms: i64, playing: bool, now: i64) {
        let end = self.duration_ms.unwrap_or(i64::MAX);
        self.position_ms = position_ms.clamp(0, end);
        self.as_of = now;
        self.playing = playing;
    }

    fn buffering_names(&self, older_than: Option<Duration>) -> Vec<String> {
        self.participants
            .iter()
            .filter(|p| p.state == PState::Buffering)
            .filter(|p| older_than.is_none_or(|d| p.buffering_since.elapsed() >= d))
            .map(|p| p.name.clone())
            .collect()
    }

    /// A user play/pause/seek: clear auto-wait and restart everyone's buffering grace.
    fn user_took_control(&mut self) {
        self.waiting.clear();
        self.paused_by_wait = false;
        let now = Instant::now();
        for p in &mut self.participants {
            if p.state == PState::Buffering {
                p.buffering_since = now;
            }
        }
    }
}

struct Conn {
    who: Identity, // name is the display label ("Alex (2)" with a device label)
    joined: bool,
    tx: UnboundedSender<Message>,
}

pub struct Hub {
    conns: HashMap<String, Conn>,
    room: Option<Room>,
    rev: u64,
    next_conn: u64,
    grace: Duration,
    wait_threshold: Duration,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
enum ClientMsg {
    Ping { client_time: Option<Value> },
    Start { movie_id: String },
    Join,
    Leave,
    Play { position_ms: f64 },
    Pause { position_ms: f64 },
    Seek { position_ms: f64 },
    Status {
        state: PState,
        #[allow(dead_code)] // accepted per protocol; the server does not use it yet
        position_ms: Option<f64>,
        duration_ms: Option<f64>,
    },
    Chat { text: String, movie_ms: Option<f64> },
    GeneralChat { text: String },
    ChatPage { movie_id: String, before: Option<i64> },
    SetAutoWait { enabled: bool },
}

fn ms(v: f64) -> i64 {
    if v.is_finite() { v.round().max(0.0) as i64 } else { 0 }
}

fn text(v: Value) -> Message {
    Message::Text(v.to_string().into())
}

impl Hub {
    pub fn new(grace: Duration, wait_threshold: Duration) -> Hub {
        Hub { conns: HashMap::new(), room: None, rev: 0, next_conn: 0, grace, wait_threshold }
    }

    pub fn room_json(&self) -> Value {
        self.room.as_ref().map(|r| r.to_json()).unwrap_or(Value::Null)
    }

    fn send(&self, conn_id: &str, msg: Value) {
        if let Some(c) = self.conns.get(conn_id) {
            let _ = c.tx.send(text(msg));
        }
    }

    fn bump_and_broadcast(&mut self) {
        self.rev += 1;
        if let Some(r) = self.room.as_mut() {
            r.rev = self.rev;
        }
        let msg = json!({"type": "room", "room": self.room_json()}).to_string();
        for c in self.conns.values() {
            let _ = c.tx.send(Message::Text(msg.clone().into()));
        }
    }

    fn send_history(&self, state: &AppState, conn_ids: &[String]) {
        let Some(room) = self.room.as_ref() else { return };
        let messages = state.db.history(&room.movie.id, CHAT_HISTORY).unwrap_or_else(|e| {
            tracing::error!(error = %e, "chat history");
            Vec::new()
        });
        let msg = json!({"type": "chatHistory", "movieId": room.movie.id, "messages": messages});
        for id in conn_ids {
            self.send(id, msg.clone());
        }
    }

    fn register(&mut self, who: Identity, tx: UnboundedSender<Message>) -> String {
        self.next_conn += 1;
        let conn_id = format!("c{}", self.next_conn);
        let welcome = json!({
            "type": "welcome",
            "you": {"userId": who.user_id, "name": who.name, "connId": conn_id},
            "serverTime": now_ms(),
            "room": self.room_json(),
        });
        let _ = tx.send(text(welcome));
        self.conns.insert(conn_id.clone(), Conn { who, joined: false, tx });
        conn_id
    }

    fn unregister(&mut self, conn_id: &str) {
        if self.conns.get(conn_id).is_some_and(|c| c.joined) {
            self.remove_participant(conn_id);
            self.conns.remove(conn_id);
            self.bump_and_broadcast();
            self.evaluate();
        } else {
            self.conns.remove(conn_id);
        }
    }

    fn remove_participant(&mut self, conn_id: &str) {
        if let Some(c) = self.conns.get_mut(conn_id) {
            c.joined = false;
        }
        if let Some(r) = self.room.as_mut() {
            r.participants.retain(|p| p.conn_id != conn_id);
            if r.participants.is_empty() {
                r.empty_since = Some(Instant::now());
            }
        }
    }

    fn add_participant(&mut self, conn_id: &str) {
        let Some(c) = self.conns.get_mut(conn_id) else { return };
        if c.joined {
            return;
        }
        c.joined = true;
        let p = Participant {
            conn_id: conn_id.to_string(),
            user_id: c.who.user_id.clone(),
            name: c.who.name.clone(),
            state: PState::Buffering,
            buffering_since: Instant::now(),
        };
        if let Some(r) = self.room.as_mut() {
            r.participants.push(p);
            r.empty_since = None;
        }
    }

    /// Auto-wait and grace-close rules. Called after every change and from the ticker.
    pub fn evaluate(&mut self) {
        let now = now_ms();
        let threshold = self.wait_threshold;
        let grace = self.grace;
        let mut changed = false;
        let mut close = false;
        if let Some(r) = self.room.as_mut() {
            if let Some(end) = r.duration_ms.filter(|&d| r.playing && r.effective_position(now) >= d) {
                r.anchor(end, false, now);
                r.paused_by_wait = false;
                r.waiting.clear();
                r.last_action = Some(LastAction { by: String::new(), action: "ended".into(), at: now, conn_id: None });
                changed = true;
            } else if r.playing && r.auto_wait {
                let late = r.buffering_names(Some(threshold));
                if !late.is_empty() {
                    let pos = r.effective_position(now);
                    r.anchor(pos, false, now);
                    r.paused_by_wait = true;
                    r.last_action = Some(LastAction { by: late.join(", "), action: "autoWait".into(), at: now, conn_id: None });
                    r.waiting = late;
                    changed = true;
                }
            } else if r.paused_by_wait && !r.playing {
                let buffering = r.buffering_names(None);
                if buffering.is_empty() && !r.participants.is_empty() {
                    let by = r.waiting.join(", ");
                    let pos = r.position_ms;
                    r.anchor(pos, true, now);
                    r.paused_by_wait = false;
                    r.waiting.clear();
                    r.last_action = Some(LastAction { by, action: "autoResume".into(), at: now, conn_id: None });
                    changed = true;
                } else if !buffering.is_empty() && buffering != r.waiting {
                    r.waiting = buffering;
                    changed = true;
                }
            }
            if r.participants.is_empty() && r.empty_since.is_some_and(|t| t.elapsed() >= grace) {
                close = true;
            }
        }
        if close {
            tracing::info!("room closed after grace period");
            self.room = None;
            self.broadcast_null();
        } else if changed {
            self.bump_and_broadcast();
        }
    }

    fn broadcast_null(&mut self) {
        self.rev += 1;
        let msg = json!({"type": "room", "room": Value::Null}).to_string();
        for c in self.conns.values_mut() {
            c.joined = false;
            let _ = c.tx.send(Message::Text(msg.clone().into()));
        }
    }

    fn handle(&mut self, state: &AppState, conn_id: &str, raw: &str) -> Result<(), String> {
        let msg: ClientMsg = serde_json::from_str(raw).map_err(|e| format!("bad message: {e}"))?;
        let now = now_ms();
        let (joined, who) = {
            let c = self.conns.get(conn_id).ok_or("unknown connection")?;
            (c.joined, c.who.clone())
        };
        match msg {
            ClientMsg::Ping { client_time } => {
                self.send(conn_id, json!({"type": "pong", "clientTime": client_time, "serverTime": now_ms()}));
                return Ok(());
            }
            ClientMsg::GeneralChat { text } => {
                let text = text.trim();
                if text.is_empty() || text.chars().count() > CHAT_MAX_CHARS {
                    return Err(format!("chat text must be 1-{CHAT_MAX_CHARS} characters"));
                }
                let mut m = ChatMessage {
                    id: 0, movie_id: "general".into(), user_id: who.user_id.clone(),
                    name: who.name.clone(), text: text.into(), movie_ms: None, sent_at: now,
                };
                m.id = state.db.insert_message(&m).map_err(|e| format!("chat not saved: {e}"))?;
                let out = json!({"type": "generalChat", "message": m}).to_string();
                for c in self.conns.values() {
                    let _ = c.tx.send(Message::Text(out.clone().into()));
                }
                return Ok(());
            }
            ClientMsg::ChatPage { movie_id, before } => {
                if movie_id != "general" && state.library.read().unwrap().get(&movie_id).is_none() {
                    return Err("unknown chat".into());
                }
                let mut messages = state.db.history_before(&movie_id, CHAT_HISTORY + 1, before)
                    .map_err(|e| format!("chat history unavailable: {e}"))?;
                let has_more = messages.len() > CHAT_HISTORY;
                if has_more { messages.remove(0); }
                self.send(conn_id, json!({"type": "chatPage", "movieId": movie_id,
                    "messages": messages, "hasMore": has_more, "before": before}));
                return Ok(());
            }
            ClientMsg::Start { movie_id } => {
                let movie = state.library.read().unwrap().get(&movie_id).map(|r| r.movie.clone());
                let movie = movie.ok_or_else(|| format!("unknown movie {movie_id}"))?;
                let action = Some(LastAction { by: who.name.clone(), action: "start".into(), at: now, conn_id: Some(conn_id.to_string()) });
                match self.room.as_mut() {
                    None => {
                        self.room = Some(Room {
                            movie,
                            playing: false,
                            position_ms: 0,
                            as_of: now,
                            duration_ms: None,
                            auto_wait: true,
                            waiting: Vec::new(),
                            paused_by_wait: false,
                            last_action: action,
                            participants: Vec::new(),
                            started_by: who.name.clone(),
                            started_at: now,
                            rev: 0,
                            empty_since: None,
                        });
                    }
                    Some(r) => {
                        r.movie = movie;
                        r.anchor(0, false, now);
                        r.duration_ms = None;
                        r.waiting.clear();
                        r.paused_by_wait = false;
                        r.last_action = action;
                        r.started_by = who.name.clone();
                        r.started_at = now;
                        let t = Instant::now();
                        for p in &mut r.participants {
                            p.state = PState::Buffering;
                            p.buffering_since = t;
                        }
                    }
                }
                self.add_participant(conn_id);
                self.bump_and_broadcast();
                let joined_ids: Vec<String> =
                    self.conns.iter().filter(|(_, c)| c.joined).map(|(id, _)| id.clone()).collect();
                self.send_history(state, &joined_ids);
                return Ok(());
            }
            ClientMsg::Join => {
                if self.room.is_none() {
                    return Err("no room to join".into());
                }
                if !joined {
                    self.add_participant(conn_id);
                    self.bump_and_broadcast();
                    self.evaluate();
                }
                self.send_history(state, &[conn_id.to_string()]);
                return Ok(());
            }
            _ if !joined => return Err("join the room first".into()),
            ClientMsg::Leave => {
                self.remove_participant(conn_id);
                self.bump_and_broadcast();
                self.evaluate();
                return Ok(());
            }
            ClientMsg::Chat { text, movie_ms } => {
                let text = text.trim();
                let n = text.chars().count();
                if n == 0 || n > CHAT_MAX_CHARS {
                    return Err(format!("chat text must be 1-{CHAT_MAX_CHARS} characters"));
                }
                let movie_id = self.room.as_ref().map(|r| r.movie.id.clone()).ok_or("no room")?;
                let mut m = ChatMessage {
                    id: 0,
                    movie_id,
                    user_id: who.user_id.clone(),
                    name: who.name.clone(),
                    text: text.to_string(),
                    movie_ms: movie_ms.map(ms),
                    sent_at: now,
                };
                m.id = state.db.insert_message(&m).map_err(|e| format!("chat not saved: {e}"))?;
                let out = json!({"type": "chat", "message": m}).to_string();
                for c in self.conns.values().filter(|c| c.joined) {
                    let _ = c.tx.send(Message::Text(out.clone().into()));
                }
                return Ok(());
            }
            _ => {}
        }

        let r = self.room.as_mut().ok_or("no room")?;
        let mut changed = true;
        match msg {
            ClientMsg::Play { position_ms } => {
                r.anchor(ms(position_ms), true, now);
                r.user_took_control();
                r.last_action = Some(LastAction { by: who.name.clone(), action: "play".into(), at: now, conn_id: Some(conn_id.to_string()) });
            }
            ClientMsg::Pause { position_ms } => {
                r.anchor(ms(position_ms), false, now);
                r.user_took_control();
                r.last_action = Some(LastAction { by: who.name.clone(), action: "pause".into(), at: now, conn_id: Some(conn_id.to_string()) });
            }
            ClientMsg::Seek { position_ms } => {
                let playing = r.playing;
                r.anchor(ms(position_ms), playing, now);
                r.user_took_control();
                r.last_action = Some(LastAction { by: who.name.clone(), action: "seek".into(), at: now, conn_id: Some(conn_id.to_string()) });
            }
            ClientMsg::SetAutoWait { enabled } => {
                r.auto_wait = enabled;
                if !enabled && r.paused_by_wait {
                    let pos = r.position_ms;
                    r.anchor(pos, true, now);
                    r.paused_by_wait = false;
                    r.waiting.clear();
                }
                r.last_action = Some(LastAction { by: who.name.clone(), action: "setAutoWait".into(), at: now, conn_id: Some(conn_id.to_string()) });
            }
            ClientMsg::Status { state: st, position_ms: _, duration_ms } => {
                changed = false;
                if let Some(p) = r.participants.iter_mut().find(|p| p.conn_id == conn_id) {
                    if p.state != st {
                        p.state = st;
                        if st == PState::Buffering {
                            p.buffering_since = Instant::now();
                        }
                        changed = true;
                    }
                }
                if r.duration_ms.is_none() {
                    if let Some(d) = duration_ms.map(ms).filter(|d| *d > 0) {
                        r.duration_ms = Some(d);
                        changed = true;
                    }
                }
            }
            _ => unreachable!(),
        }
        if changed {
            self.bump_and_broadcast();
        }
        self.evaluate();
        Ok(())
    }
}

pub async fn ticker(state: Arc<AppState>) {
    let mut iv = tokio::time::interval(Duration::from_millis(100));
    iv.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        iv.tick().await;
        state.hub.lock().unwrap().evaluate();
    }
}

pub async fn run_socket(state: Arc<AppState>, socket: WebSocket, who: Identity) {
    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = unbounded_channel::<Message>();
    let conn_id = state.hub.lock().unwrap().register(who.clone(), tx.clone());
    tracing::info!(conn_id, user = who.user_id, name = who.name, "socket open");

    let writer = tokio::spawn(async move {
        let mut ping = tokio::time::interval(PING_EVERY);
        ping.tick().await;
        loop {
            tokio::select! {
                m = rx.recv() => {
                    let Some(m) = m else { break };
                    let close = matches!(m, Message::Close(_));
                    if sink.send(m).await.is_err() || close { break; }
                }
                _ = ping.tick() => {
                    if sink.send(Message::Ping(Vec::new().into())).await.is_err() { break; }
                }
            }
        }
    });

    loop {
        let next = tokio::time::timeout(IDLE_TIMEOUT, stream.next()).await;
        let msg = match next {
            Err(_) => {
                tracing::info!(conn_id, "socket idle timeout");
                break;
            }
            Ok(None) | Ok(Some(Err(_))) => break,
            Ok(Some(Ok(m))) => m,
        };
        match msg {
            Message::Text(t) => {
                let mut hub = state.hub.lock().unwrap();
                if let Err(e) = hub.handle(&state, &conn_id, t.as_str()) {
                    hub.send(&conn_id, json!({"type": "error", "message": e}));
                }
            }
            Message::Close(_) => break,
            _ => {} // ping/pong/binary: activity only
        }
    }

    state.hub.lock().unwrap().unregister(&conn_id);
    let _ = tx.send(Message::Close(None));
    drop(tx);
    let _ = writer.await;
    tracing::info!(conn_id, "socket closed");
}

// Public synthetic harness adapters. Room/protocol behavior above is extracted source.
pub(crate) fn harness_register(hub: &mut Hub, name: &str) -> String {
    let (tx, _rx) = unbounded_channel();
    hub.register(Identity { user_id: name.to_lowercase(), name: name.into() }, tx)
}
pub(crate) fn harness_handle(hub: &mut Hub, state: &AppState, conn: &str, message: &str) -> Result<(), String> {
    hub.handle(state, conn, message)
}
