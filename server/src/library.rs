// Synthetic facade for the original room/database modules; no media scanning.
use crate::db::IndexedRow;
use serde::Serialize;
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Movie {
    pub id: String, pub title: String, pub year: Option<i32>, pub quality: Option<String>,
    pub container: String, pub size_bytes: i64, pub added_at: i64,
}
pub struct Library { pub rows: Vec<IndexedRow> }
impl Library {
    pub fn get(&self, id: &str) -> Option<&IndexedRow> { self.rows.iter().find(|r| r.movie.id == id) }
    pub fn synthetic() -> Self { Self { rows: vec![IndexedRow {
        movie: Movie { id: "synthetic-movie".into(), title: "Synthetic Film".into(), year: None, quality: None, container: "mp4".into(), size_bytes: 0, added_at: 0 },
        root: String::new(), rel_path: String::new(),
    }] } }
}
