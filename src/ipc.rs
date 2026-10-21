use crate::{
    Result,
    control::{Reply, Request},
};
use std::{
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, Read, Write},
    os::{
        fd::AsRawFd,
        unix::{
            fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt},
            net::{UnixListener, UnixStream},
        },
    },
    path::{Path, PathBuf},
    time::Duration,
};

const MAX_MESSAGE: u64 = 4096;

pub(crate) fn runtime_dir() -> Result<PathBuf> {
    // SAFETY: geteuid has no arguments or memory preconditions.
    let uid = unsafe { libc::geteuid() };
    let path = std::env::var_os("AUDIOBOOST_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join(format!("audioboost-{uid}")));
    if !path.is_absolute() {
        return Err("runtime directory must be absolute".into());
    }
    match fs::DirBuilder::new().mode(0o700).create(&path) {
        Ok(()) => (),
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => (),
        Err(error) => return Err(error.into()),
    }
    let metadata = fs::symlink_metadata(&path)?;
    if !metadata.is_dir() || metadata.uid() != uid || metadata.mode() & 0o077 != 0 {
        return Err(
            "runtime directory must be a private directory owned by you (mode 0700)".into(),
        );
    }
    Ok(path)
}

pub(crate) fn socket_path(dir: &Path) -> PathBuf {
    dir.join("control.sock")
}

pub(crate) fn read_message<T: serde::de::DeserializeOwned>(reader: impl Read) -> Result<T> {
    let mut bytes = Vec::new();
    BufReader::new(reader.take(MAX_MESSAGE + 1)).read_until(b'\n', &mut bytes)?;
    if bytes.len() as u64 > MAX_MESSAGE || bytes.last() != Some(&b'\n') {
        return Err("incomplete or oversized control message".into());
    }
    Ok(serde_json::from_slice(&bytes)?)
}

pub(crate) fn write_message(writer: &mut impl Write, value: &impl serde::Serialize) -> Result<()> {
    let mut bytes = serde_json::to_vec(value)?;
    bytes.push(b'\n');
    if bytes.len() as u64 > MAX_MESSAGE {
        return Err("control response too large".into());
    }
    writer.write_all(&bytes)?;
    Ok(())
}

pub(crate) fn verify_peer(stream: &UnixStream) -> Result<()> {
    let (mut uid, mut gid) = (0, 0);
    // SAFETY: stream owns a live socket; uid/gid point to initialized, writable values.
    if unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    // SAFETY: geteuid has no arguments or memory preconditions.
    if uid != unsafe { libc::geteuid() } {
        return Err("control socket belongs to a different user".into());
    }
    Ok(())
}

pub(crate) fn connect(dir: &Path) -> std::io::Result<UnixStream> {
    UnixStream::connect(socket_path(dir))
}

pub(crate) fn configure_client(stream: &UnixStream) -> Result<()> {
    verify_peer(stream)?;
    // Darwin may inherit O_NONBLOCK from the listening socket.
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_millis(200)))?;
    stream.set_write_timeout(Some(Duration::from_millis(200)))?;
    Ok(())
}

pub(crate) fn request(dir: &Path, request: &Request) -> Result<Reply> {
    let mut stream = connect(dir)?;
    verify_peer(&stream)?;
    // Starting audio can display the macOS permission dialog.
    let timeout = if matches!(request, Request::Start(_)) {
        60
    } else {
        2
    };
    stream.set_read_timeout(Some(Duration::from_secs(timeout)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    write_message(&mut stream, request)?;
    let reply: Reply = read_message(stream)?;
    if let Some(error) = &reply.error {
        return Err(error.clone().into());
    }
    Ok(reply)
}

pub(crate) struct Server {
    pub listener: UnixListener,
    path: PathBuf,
    _lock: File,
}

impl Server {
    pub fn bind(dir: &Path) -> Result<Self> {
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(dir.join("service.lock"))?;
        // SAFETY: lock is an owned file descriptor retained for the server lifetime.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err("another AudioBoost service is already running".into());
        }
        let path = socket_path(dir);
        match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_socket() => fs::remove_file(&path)?,
            Ok(_) => return Err("refusing to replace a non-socket control path".into()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
            Err(error) => return Err(error.into()),
        }
        let listener = UnixListener::bind(&path)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;
        Ok(Self {
            listener,
            path,
            _lock: lock,
        })
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn framing_rejects_truncation_oversize_and_invalid_gain() {
        assert!(read_message::<Request>(&b"\"Status\""[..]).is_err());
        assert!(read_message::<Request>(&vec![b' '; 4097][..]).is_err());
        assert!(read_message::<Request>(&b"{\"Gain\":99}\n"[..]).is_err());
        assert!(matches!(
            read_message::<Request>(&b"\"Status\"\n"[..]).unwrap(),
            Request::Status
        ));
    }
    #[test]
    fn service_lock_prevents_two_owners_and_allows_restart() {
        let dir = std::env::temp_dir().join(format!("ab-lock-test-{}", std::process::id()));
        fs::create_dir(&dir).unwrap();
        let first = Server::bind(&dir).unwrap();
        assert!(Server::bind(&dir).is_err());
        drop(first);
        assert!(!socket_path(&dir).exists());
        drop(Server::bind(&dir).unwrap());
        fs::remove_dir_all(dir).unwrap();
    }
}
