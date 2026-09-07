use std::{
    fs::File,
    io::{self, Read, Write},
    os::fd::OwnedFd,
    path::PathBuf,
};

use rustix::fs::{
    AtFlags, FileType, Mode, OFlags, RenameFlags, fstat, fsync, open, openat, renameat_with,
    unlinkat,
};

use crate::{
    DEPLOYMENT_MARKER_FILE_NAME, DEPLOYMENT_MARKER_SIZE, DeploymentQuarantineMarker,
    LoadedDeploymentMarker, MarkerError, MarkerFingerprint, fingerprint,
};

const PARENT_MODE: u32 = 0o700;
const MARKER_MODE: u32 = 0o600;

/// Secure Linux store for the deployment-owned quarantine marker.
#[derive(Clone, Debug)]
pub struct DeploymentMarkerStore {
    parent: PathBuf,
    expected_uid: u32,
}

impl DeploymentMarkerStore {
    #[must_use]
    pub fn new(parent: impl Into<PathBuf>, expected_uid: u32) -> Self {
        Self {
            parent: parent.into(),
            expected_uid,
        }
    }

    #[must_use]
    pub fn marker_path(&self) -> PathBuf {
        self.parent.join(DEPLOYMENT_MARKER_FILE_NAME)
    }

    /// Publish once. An existing file, including a symlink, is never replaced.
    ///
    /// # Errors
    ///
    /// Returns [`MarkerError`] when the marker is invalid, storage metadata is
    /// unsafe, a destination already exists, or durable publication fails.
    pub fn publish(
        &self,
        marker: &DeploymentQuarantineMarker,
    ) -> Result<MarkerFingerprint, MarkerError> {
        let bytes = marker.encode()?;
        let parent = self.open_parent()?;
        let temporary_name = temporary_name("publish", marker);
        let temporary_fd = match openat(
            &parent,
            temporary_name.as_str(),
            OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::RUSR | Mode::WUSR,
        ) {
            Ok(fd) => fd,
            Err(source) => return Err(io_error("create deployment marker temporary file", source)),
        };
        let mut temporary = File::from(temporary_fd);
        if let Err(source) = temporary
            .write_all(&bytes)
            .and_then(|()| temporary.sync_all())
        {
            let _ = unlinkat(&parent, temporary_name.as_str(), AtFlags::empty());
            return Err(io_error("write deployment marker temporary file", source));
        }
        drop(temporary);

        if let Err(source) = renameat_with(
            &parent,
            temporary_name.as_str(),
            &parent,
            DEPLOYMENT_MARKER_FILE_NAME,
            RenameFlags::NOREPLACE,
        ) {
            let _ = unlinkat(&parent, temporary_name.as_str(), AtFlags::empty());
            if source == rustix::io::Errno::EXIST {
                return Err(MarkerError::MarkerAlreadyExists);
            }
            return Err(io_error("publish deployment marker", source));
        }
        fsync(&parent).map_err(|source| io_error("sync deployment marker parent", source))?;

        let loaded = self.load_from_parent(&parent, DEPLOYMENT_MARKER_FILE_NAME, 1)?;
        Ok(loaded.fingerprint)
    }

    /// Load the active marker. Invalid storage or content is an error and must
    /// be interpreted by the admission consumer as fail-closed.
    ///
    /// # Errors
    ///
    /// Returns [`MarkerError`] when the parent or marker is missing, unsafe,
    /// malformed, or cannot be read.
    pub fn load(&self) -> Result<LoadedDeploymentMarker, MarkerError> {
        let parent = self.open_parent()?;
        self.load_from_parent(&parent, DEPLOYMENT_MARKER_FILE_NAME, 1)
    }

    fn open_parent(&self) -> Result<OwnedFd, MarkerError> {
        if !self.parent.is_absolute() {
            return Err(MarkerError::PathMustBeAbsolute);
        }
        let fd = open(
            &self.parent,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(|source| io_error("open deployment marker parent", source))?;
        let metadata =
            fstat(&fd).map_err(|source| io_error("stat deployment marker parent", source))?;
        if FileType::from_raw_mode(metadata.st_mode) != FileType::Directory
            || metadata.st_uid != self.expected_uid
            || metadata.st_mode & 0o777 != PARENT_MODE
        {
            return Err(MarkerError::UnsafeParent);
        }
        Ok(fd)
    }

    fn load_from_parent(
        &self,
        parent: &OwnedFd,
        name: &str,
        expected_links: u64,
    ) -> Result<LoadedDeploymentMarker, MarkerError> {
        let fd = match openat(
            parent,
            name,
            OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        ) {
            Ok(fd) => fd,
            Err(source) if source == rustix::io::Errno::NOENT => {
                return Err(MarkerError::MarkerMissing);
            }
            Err(source) => return Err(io_error("open deployment marker", source)),
        };
        let metadata = fstat(&fd).map_err(|source| io_error("stat deployment marker", source))?;
        let expected_size = i64::try_from(DEPLOYMENT_MARKER_SIZE).expect("marker size fits i64");
        if FileType::from_raw_mode(metadata.st_mode) != FileType::RegularFile
            || metadata.st_uid != self.expected_uid
            || metadata.st_mode & 0o777 != MARKER_MODE
            || metadata.st_nlink != expected_links
            || metadata.st_size != expected_size
        {
            return Err(MarkerError::UnsafeMarker);
        }

        let mut bytes = Vec::with_capacity(DEPLOYMENT_MARKER_SIZE + 1);
        File::from(fd)
            .take(u64::try_from(DEPLOYMENT_MARKER_SIZE + 1).expect("marker size fits u64"))
            .read_to_end(&mut bytes)
            .map_err(|source| io_error("read deployment marker", source))?;
        if bytes.len() != DEPLOYMENT_MARKER_SIZE {
            return Err(MarkerError::WrongSize {
                actual: bytes.len(),
            });
        }
        let marker = DeploymentQuarantineMarker::decode(&bytes)?;
        let fingerprint = fingerprint(&marker, &bytes);
        Ok(LoadedDeploymentMarker {
            marker,
            fingerprint,
        })
    }
}

fn temporary_name(kind: &str, marker: &DeploymentQuarantineMarker) -> String {
    format!(
        ".{DEPLOYMENT_MARKER_FILE_NAME}.{kind}.{}.{}.{}",
        std::process::id(),
        marker.generation,
        hex_lower(&marker.coordinator_instance)
    )
}

fn hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(char::from(HEX[usize::from(byte >> 4)]));
        output.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    output
}

fn io_error(action: &'static str, source: impl Into<io::Error>) -> MarkerError {
    MarkerError::Io {
        action,
        source: source.into(),
    }
}
