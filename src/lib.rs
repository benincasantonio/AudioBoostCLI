//! Commands and gain contracts shared by the CLI and background service.
#[cfg(not(miri))]
mod app;
pub mod control;
#[cfg(not(miri))]
mod engine;
#[cfg(not(miri))]
mod ipc;
#[cfg(not(miri))]
mod terminal;
#[cfg(not(miri))]
pub use app::run;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
