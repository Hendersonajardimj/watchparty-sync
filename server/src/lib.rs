pub mod db;
pub mod room;
pub mod harness;
pub mod library;
pub mod identity;
use std::sync::{Mutex, RwLock};
pub struct AppState { pub db: db::Db, pub library: RwLock<library::Library>, pub hub: Mutex<room::Hub> }
