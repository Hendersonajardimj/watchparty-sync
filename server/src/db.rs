//! SQLite: chat messages (persist across rooms) and a cache of the library index.

use crate::library::Movie;
use rusqlite::{params, Connection};
use serde::Serialize;
use std::path::Path;
use std::sync::Mutex;

pub struct Db {
    conn: Mutex<Connection>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatMessage {
    pub id: i64,
    pub movie_id: String,
    pub user_id: String,
    pub name: String,
    pub text: String,
    pub movie_ms: Option<i64>,
    pub sent_at: i64,
}

/// A cached index row: the movie plus where its file lives.
pub struct IndexedRow {
    pub movie: Movie,
    pub root: String,
    pub rel_path: String,
}

impl Db {
    pub fn open(path: &Path) -> rusqlite::Result<Db> {
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=NORMAL;
             CREATE TABLE IF NOT EXISTS messages (
               id INTEGER PRIMARY KEY AUTOINCREMENT,
               movie_id TEXT NOT NULL,
               user_id TEXT NOT NULL,
               name TEXT NOT NULL,
               text TEXT NOT NULL,
               movie_ms INTEGER,
               sent_at INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS messages_movie ON messages(movie_id, id);
             CREATE TABLE IF NOT EXISTS movies (
               id TEXT PRIMARY KEY,
               root TEXT NOT NULL,
               rel_path TEXT NOT NULL,
               title TEXT NOT NULL,
               year INTEGER,
               quality TEXT,
               container TEXT NOT NULL,
               size_bytes INTEGER NOT NULL,
               added_at INTEGER NOT NULL
             );",
        )?;
        Ok(Db { conn: Mutex::new(conn) })
    }

    pub fn insert_message(&self, m: &ChatMessage) -> rusqlite::Result<i64> {
        let c = self.conn.lock().unwrap();
        c.execute(
            "INSERT INTO messages (movie_id, user_id, name, text, movie_ms, sent_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![m.movie_id, m.user_id, m.name, m.text, m.movie_ms, m.sent_at],
        )?;
        Ok(c.last_insert_rowid())
    }

    /// Last `limit` messages for a movie, oldest first.
    pub fn history(&self, movie_id: &str, limit: usize) -> rusqlite::Result<Vec<ChatMessage>> {
        self.history_before(movie_id, limit, None)
    }

    pub fn history_before(&self, movie_id: &str, limit: usize, before: Option<i64>) -> rusqlite::Result<Vec<ChatMessage>> {
        let c = self.conn.lock().unwrap();
        let mut st = c.prepare(
            "SELECT id, movie_id, user_id, name, text, movie_ms, sent_at FROM messages
             WHERE movie_id = ?1 AND (?3 IS NULL OR id < ?3) ORDER BY id DESC LIMIT ?2",
        )?;
        let mut rows: Vec<ChatMessage> = st
            .query_map(params![movie_id, limit as i64, before], |r| {
                Ok(ChatMessage {
                    id: r.get(0)?,
                    movie_id: r.get(1)?,
                    user_id: r.get(2)?,
                    name: r.get(3)?,
                    text: r.get(4)?,
                    movie_ms: r.get(5)?,
                    sent_at: r.get(6)?,
                })
            })?
            .collect::<Result<_, _>>()?;
        rows.reverse();
        Ok(rows)
    }

    pub fn load_index(&self) -> rusqlite::Result<Vec<IndexedRow>> {
        let c = self.conn.lock().unwrap();
        let mut st = c.prepare(
            "SELECT id, root, rel_path, title, year, quality, container, size_bytes, added_at FROM movies",
        )?;
        let rows = st
            .query_map([], |r| {
                Ok(IndexedRow {
                    movie: Movie {
                        id: r.get(0)?,
                        title: r.get(3)?,
                        year: r.get(4)?,
                        quality: r.get(5)?,
                        container: r.get(6)?,
                        size_bytes: r.get(7)?,
                        added_at: r.get(8)?,
                    },
                    root: r.get(1)?,
                    rel_path: r.get(2)?,
                })
            })?
            .collect::<Result<_, _>>()?;
        Ok(rows)
    }

    pub fn save_index(&self, rows: &[IndexedRow]) -> rusqlite::Result<()> {
        let mut c = self.conn.lock().unwrap();
        let tx = c.transaction()?;
        tx.execute("DELETE FROM movies", [])?;
        {
            let mut st = tx.prepare(
                "INSERT OR REPLACE INTO movies (id, root, rel_path, title, year, quality, container, size_bytes, added_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            )?;
            for r in rows {
                let m = &r.movie;
                st.execute(params![
                    m.id, r.root, r.rel_path, m.title, m.year, m.quality, m.container, m.size_bytes, m.added_at
                ])?;
            }
        }
        tx.commit()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chat_survives_reopen_and_pages_without_crossing_channels() {
        let path = std::env::temp_dir().join(format!("watchparty-chat-{}.db", std::process::id()));
        {
            let db = Db::open(&path).unwrap();
            for i in 0..205 {
                let m = ChatMessage { id: 0, movie_id: "general".into(), user_id: "alex".into(),
                    name: "Alex".into(), text: format!("message {i}"), movie_ms: None, sent_at: i };
                db.insert_message(&m).unwrap();
            }
            let m = ChatMessage { id: 0, movie_id: "movie".into(), user_id: "casey".into(),
                name: "Casey".into(), text: "movie only".into(), movie_ms: Some(123), sent_at: 206 };
            db.insert_message(&m).unwrap();
        }
        let db = Db::open(&path).unwrap();
        let latest = db.history_before("general", 200, None).unwrap();
        assert_eq!(latest.len(), 200);
        assert_eq!(latest.first().unwrap().text, "message 5");
        let older = db.history_before("general", 200, Some(latest[0].id)).unwrap();
        assert_eq!(older.len(), 5);
        assert_eq!(older[0].text, "message 0");
        assert!(older.last().unwrap().id < latest[0].id);
        assert_eq!(db.history("movie", 200).unwrap()[0].movie_ms, Some(123));
        drop(db);
        let _ = std::fs::remove_file(path);
    }
}
