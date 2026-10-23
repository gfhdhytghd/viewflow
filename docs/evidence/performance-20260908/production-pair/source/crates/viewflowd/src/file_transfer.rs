//! Bounded, fail-closed receiver for reliable file-drag blobs.

use std::{
    collections::VecDeque,
    fs::{File, OpenOptions},
    io::{Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::{Arc, OnceLock},
};

use sha2::{Digest, Sha256};
#[cfg(not(windows))]
use tempfile::TempDir;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use viewflow_core::{DragTransfers, TransferError};
use viewflow_protocol::{DragComplete, DragCompletionStatus, DragItemResult, DragOffer};
use viewflow_transport::BlobChunk;

const MAX_TOTAL_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const QUOTA_UNIT_BYTES: u64 = 1024 * 1024;
const GLOBAL_QUOTA_UNITS: usize = 8 * 1024;
const REPLAY_CACHE_ENTRIES: usize = 8 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct AcceptedChunk {
    item_index: usize,
    offset_bytes: u64,
    payload_len: usize,
    final_chunk: bool,
    payload_hash: [u8; 32],
}

fn global_quota() -> &'static Arc<Semaphore> {
    static QUOTA: OnceLock<Arc<Semaphore>> = OnceLock::new();
    QUOTA.get_or_init(|| Arc::new(Semaphore::new(GLOBAL_QUOTA_UNITS)))
}

fn quota_units(total: u64) -> Result<u32, TransferError> {
    u32::try_from(total.div_ceil(QUOTA_UNIT_BYTES).max(1)).map_err(|_| TransferError::QuotaExceeded)
}

#[derive(Debug)]
pub(crate) struct InboundFileTransfer {
    pub(crate) root: PathBuf,
    // Retaining the handle makes every partial/error/disconnect path remove the
    // private tree automatically. Files are deliberately stored under opaque
    // local names; sender-controlled paths are metadata until a later,
    // separately authorized destination commit.
    _quota: OwnedSemaphorePermit,
    offer: DragOffer,
    state: DragTransfers,
    files: Vec<File>,
    hashes: Vec<Sha256>,
    received: Vec<u64>,
    // A bounded exact-identity cache makes reliable-stream retransmissions
    // idempotent without retaining blob payloads or accepting arbitrary
    // overlapping ranges that merely happen to match bytes on disk.
    accepted_chunks: VecDeque<AcceptedChunk>,
    // A completed transfer may receive an in-flight replay of an already
    // accepted blob. Keep the exact completion so its control ACK is stable
    // without advancing the core state a second time.
    completion: Option<DragComplete>,
    sequence: u64,
    // This must be declared after `files`: on Windows, close the child file
    // handles before the cleanup guard removes their private parent tree.
    _temp_root: TemporaryRoot,
}

/// Keeps a private temporary tree alive and removes it if its transfer is
/// abandoned. The Windows variant is deliberately not `TempDir`: its root is
/// created by `CreateDirectoryW` with the DACL already attached.
#[derive(Debug)]
struct TemporaryRoot {
    path: PathBuf,
    #[cfg(not(windows))]
    _temp_dir: TempDir,
}

impl TemporaryRoot {
    fn path(&self) -> &Path {
        &self.path
    }
}

#[cfg(any(windows, test))]
fn owner_only_tree_sddl(sid: &str) -> String {
    // P protects this DACL from parent inheritance. OI|CI ensures the same
    // owner-only ACE is inherited by every file and directory below.
    format!("O:{sid}D:P(A;OICI;FA;;;{sid})")
}

#[cfg(unix)]
fn create_temporary_root(root_parent: &Path, prefix: &str) -> std::io::Result<TemporaryRoot> {
    use std::os::unix::fs::PermissionsExt;

    let mut builder = tempfile::Builder::new();
    builder.prefix(prefix);
    builder.permissions(std::fs::Permissions::from_mode(0o700));
    let temp_dir = builder.tempdir_in(root_parent)?;
    Ok(TemporaryRoot {
        path: temp_dir.path().to_path_buf(),
        _temp_dir: temp_dir,
    })
}

#[cfg(windows)]
fn create_temporary_root(root_parent: &Path, prefix: &str) -> std::io::Result<TemporaryRoot> {
    Ok(TemporaryRoot {
        path: windows::create_owner_only_directory(root_parent, prefix)?,
    })
}

#[cfg(all(not(unix), not(windows)))]
fn create_temporary_root(root_parent: &Path, prefix: &str) -> std::io::Result<TemporaryRoot> {
    let mut builder = tempfile::Builder::new();
    builder.prefix(prefix);
    let temp_dir = builder.tempdir_in(root_parent)?;
    Ok(TemporaryRoot {
        path: temp_dir.path().to_path_buf(),
        _temp_dir: temp_dir,
    })
}

#[cfg(windows)]
impl Drop for TemporaryRoot {
    fn drop(&mut self) {
        // Best-effort cleanup matches TempDir's destructor behavior. This is
        // intentionally delayed until `InboundFileTransfer.files` has dropped.
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

#[cfg(windows)]
mod windows {
    #![allow(unsafe_code)]

    use std::{
        ffi::{OsStr, c_void},
        io,
        mem::size_of,
        os::windows::ffi::OsStrExt,
        path::{Path, PathBuf},
        ptr::null_mut,
    };

    use windows_sys::Win32::{
        Foundation::{CloseHandle, HANDLE, LocalFree},
        Security::{
            Authorization::{
                ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
                SDDL_REVISION_1,
            },
            GetTokenInformation, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, TOKEN_QUERY,
            TOKEN_USER, TokenUser,
        },
        Storage::FileSystem::CreateDirectoryW,
        System::Threading::{GetCurrentProcess, OpenProcessToken},
    };

    use super::owner_only_tree_sddl;

    /// Uses tempfile only for unpredictable candidate names. The directory
    /// itself is created atomically by `CreateDirectoryW` with a protected DACL;
    /// there is never a window where the tree exists under inherited ACLs.
    pub(super) fn create_owner_only_directory(parent: &Path, prefix: &str) -> io::Result<PathBuf> {
        let sid = current_user_sid()?;
        let descriptor = SecurityDescriptor::for_sid(&sid)?;
        let mut builder = tempfile::Builder::new();
        builder.prefix(prefix);
        let candidate = builder.make_in(parent, |path| create_directory(path, descriptor.0))?;
        let ((), mut candidate_path) = candidate.into_parts();
        let path = candidate_path.to_path_buf();
        // TempPath is designed for files and would call remove_file on this
        // directory. Transfer ownership to TemporaryRoot's directory cleanup.
        candidate_path.disable_cleanup(true);
        Ok(path)
    }

    fn create_directory(path: &Path, descriptor: PSECURITY_DESCRIPTOR) -> io::Result<()> {
        let path = wide_null(path.as_os_str());
        let attributes = SECURITY_ATTRIBUTES {
            nLength: u32::try_from(size_of::<SECURITY_ATTRIBUTES>()).unwrap(),
            lpSecurityDescriptor: descriptor,
            bInheritHandle: 0,
        };
        // SAFETY: path and security attributes remain valid for the duration
        // of the call. CreateDirectoryW either creates this exact candidate or
        // fails without modifying an existing tree.
        if unsafe { CreateDirectoryW(path.as_ptr(), &attributes) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    fn current_user_sid() -> io::Result<String> {
        let mut token = null_mut();
        // SAFETY: the pseudo process handle is valid and token is writable.
        if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let token = OwnedHandle(token);
        let mut required = 0;
        // SAFETY: this is the documented TokenUser size-query form.
        unsafe { GetTokenInformation(token.0, TokenUser, null_mut(), 0, &mut required) };
        if required < u32::try_from(size_of::<TOKEN_USER>()).unwrap() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "GetTokenInformation returned an invalid TokenUser size",
            ));
        }
        let words = usize::try_from(required)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "TokenUser size overflow"))?
            .div_ceil(size_of::<usize>());
        let mut buffer = vec![0_usize; words];
        // SAFETY: the aligned allocation is at least `required` bytes and is
        // live while the resulting TOKEN_USER and SID are read.
        if unsafe {
            GetTokenInformation(
                token.0,
                TokenUser,
                buffer.as_mut_ptr().cast(),
                required,
                &mut required,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: GetTokenInformation initialized TOKEN_USER at the aligned
        // start of buffer, and the SID belongs to that live buffer.
        let sid = unsafe { (*(buffer.as_ptr().cast::<TOKEN_USER>())).User.Sid };
        let mut sid_string = null_mut();
        // SAFETY: SID is valid and sid_string receives a LocalAlloc pointer.
        if unsafe { ConvertSidToStringSidW(sid, &mut sid_string) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let sid_string = LocalAllocation(sid_string.cast());
        wide_ptr_to_string(sid_string.0.cast())
    }

    struct SecurityDescriptor(PSECURITY_DESCRIPTOR);

    impl SecurityDescriptor {
        fn for_sid(sid: &str) -> io::Result<Self> {
            let sddl = wide_null(OsStr::new(&owner_only_tree_sddl(sid)));
            let mut descriptor = null_mut();
            // SAFETY: SDDL is null-terminated and descriptor receives the
            // LocalAlloc-owned security descriptor on success.
            if unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    sddl.as_ptr(),
                    SDDL_REVISION_1,
                    &mut descriptor,
                    null_mut(),
                )
            } == 0
            {
                return Err(io::Error::last_os_error());
            }
            Ok(Self(descriptor))
        }
    }

    impl Drop for SecurityDescriptor {
        fn drop(&mut self) {
            // SAFETY: the descriptor was returned by LocalAlloc and is freed once.
            unsafe { LocalFree(self.0.cast()) };
        }
    }

    struct OwnedHandle(HANDLE);

    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            // SAFETY: the token handle is owned and closed once.
            unsafe { CloseHandle(self.0) };
        }
    }

    struct LocalAllocation(*mut c_void);

    impl Drop for LocalAllocation {
        fn drop(&mut self) {
            // SAFETY: the pointer was returned by LocalAlloc and is freed once.
            unsafe { LocalFree(self.0) };
        }
    }

    fn wide_null(value: &OsStr) -> Vec<u16> {
        value.encode_wide().chain(Some(0)).collect()
    }

    fn wide_ptr_to_string(pointer: *const u16) -> io::Result<String> {
        if pointer.is_null() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Windows returned a null UTF-16 SID",
            ));
        }
        let mut length = 0;
        // SAFETY: ConvertSidToStringSidW returns a valid null-terminated
        // UTF-16 allocation which LocalAllocation keeps alive for this scan.
        unsafe {
            while *pointer.add(length) != 0 {
                length += 1;
            }
            String::from_utf16(std::slice::from_raw_parts(pointer, length)).map_err(|_| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Windows returned an invalid SID",
                )
            })
        }
    }
}

impl InboundFileTransfer {
    /// Creates a transfer rooted in a private temporary directory. The caller
    /// must still send the returned accept over the authenticated control stream.
    pub(crate) fn accept(
        root_parent: &Path,
        sequence: u64,
        offer: DragOffer,
    ) -> Result<Self, TransferError> {
        let total: u64 = offer
            .items
            .iter()
            .map(|item| item.size_bytes)
            .try_fold(0, u64::checked_add)
            .ok_or(TransferError::TotalSizeOverflow)?;
        if total > MAX_TOTAL_BYTES {
            return Err(TransferError::TotalSizeOverflow);
        }
        let quota_units = quota_units(total)?;
        let quota = Arc::clone(global_quota())
            .try_acquire_many_owned(quota_units)
            .map_err(|_| TransferError::QuotaExceeded)?;
        // Run core validation before creating anything on disk.
        let mut state = DragTransfers::default();
        state.offer(sequence, sequence, offer.clone())?;
        let prefix = format!("viewflow-drag-{:032x}-", offer.id.0);
        let temp_root = create_temporary_root(root_parent, &prefix)
            .map_err(|_| TransferError::InvalidDestination)?;
        let root = temp_root.path().to_path_buf();
        let mut files = Vec::with_capacity(offer.items.len());
        for index in 0..offer.items.len() {
            let path = root.join(format!("item-{index:08}.part"));
            files.push(
                OpenOptions::new()
                    .create_new(true)
                    .write(true)
                    .read(true)
                    .open(path)
                    .map_err(|_| TransferError::InvalidDestination)?,
            );
        }
        state.accept(sequence, sequence + 1, offer.id)?;
        Ok(Self {
            root,
            _quota: quota,
            files,
            hashes: (0..offer.items.len()).map(|_| Sha256::new()).collect(),
            received: vec![0; offer.items.len()],
            accepted_chunks: VecDeque::with_capacity(REPLAY_CACHE_ENTRIES),
            completion: None,
            offer,
            state,
            sequence: sequence + 1,
            _temp_root: temp_root,
        })
    }

    pub(crate) fn push(
        &mut self,
        chunk: &BlobChunk,
    ) -> Result<Option<DragComplete>, TransferError> {
        if chunk.transfer_id != self.offer.id {
            return Err(TransferError::UnknownOffer);
        }
        let index = usize::try_from(chunk.item_index).map_err(|_| TransferError::UnknownItem)?;
        let item = self
            .offer
            .items
            .get(index)
            .ok_or(TransferError::UnknownItem)?;
        if chunk.payload.is_empty() {
            return Err(TransferError::InvalidChunkOffset);
        }
        if chunk.offset_bytes > self.received[index] {
            return Err(TransferError::InvalidChunkOffset);
        }
        let end = chunk
            .offset_bytes
            .checked_add(chunk.payload.len() as u64)
            .ok_or(TransferError::ItemSizeExceeded)?;
        if end > item.size_bytes {
            return Err(TransferError::ItemSizeExceeded);
        }
        if chunk.offset_bytes < self.received[index] {
            if end > self.received[index]
                || !self
                    .accepted_chunks
                    .iter()
                    .any(|accepted| *accepted == AcceptedChunk::from_chunk(index, chunk))
            {
                return Err(TransferError::InvalidChunkOffset);
            }
            return Ok(self.completion.clone());
        }
        if chunk.final_chunk != (end == item.size_bytes) {
            return Err(TransferError::TransferIncomplete);
        }
        let file = self
            .files
            .get_mut(index)
            .ok_or(TransferError::UnknownItem)?;
        file.seek(SeekFrom::Start(chunk.offset_bytes))
            .map_err(|_| TransferError::InvalidDestination)?;
        file.write_all(&chunk.payload)
            .map_err(|_| TransferError::InvalidDestination)?;
        self.hashes[index].update(&chunk.payload);
        self.received[index] = end;
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or(TransferError::OutOfOrderSequence)?;
        self.state.chunk_progress(
            self.offer.generation,
            self.sequence,
            self.offer.id,
            index,
            chunk.offset_bytes,
            chunk.payload.len() as u64,
        )?;
        self.remember_accepted_chunk(index, chunk);
        self.completion_if_ready()
    }

    fn remember_accepted_chunk(&mut self, item_index: usize, chunk: &BlobChunk) {
        if self.accepted_chunks.len() == REPLAY_CACHE_ENTRIES {
            self.accepted_chunks.pop_front();
        }
        self.accepted_chunks
            .push_back(AcceptedChunk::from_chunk(item_index, chunk));
    }

    pub(crate) fn completion_if_ready(&mut self) -> Result<Option<DragComplete>, TransferError> {
        if let Some(completion) = &self.completion {
            return Ok(Some(completion.clone()));
        }
        if self
            .received
            .iter()
            .zip(&self.offer.items)
            .any(|(got, item)| *got != item.size_bytes)
        {
            return Ok(None);
        }
        let hashes: Vec<_> = self
            .hashes
            .iter()
            .map(|hash| Some(hash.clone().finalize().into()))
            .collect();
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or(TransferError::OutOfOrderSequence)?;
        self.state.complete(
            self.offer.generation,
            self.sequence,
            self.offer.id,
            hashes.clone(),
        )?;
        for file in &self.files {
            file.sync_all()
                .map_err(|_| TransferError::InvalidDestination)?;
        }
        let completion = DragComplete {
            offer_id: self.offer.id,
            generation: self.offer.generation,
            status: DragCompletionStatus::Completed,
            error_message: None,
            item_results: hashes
                .into_iter()
                .enumerate()
                .map(|(i, hash)| DragItemResult {
                    item_index: u32::try_from(i).unwrap_or(u32::MAX),
                    bytes_received: self.received[i],
                    content_hash: hash,
                })
                .collect(),
        };
        self.completion = Some(completion.clone());
        Ok(Some(completion))
    }

    pub(crate) fn matches(&self, offer_id: viewflow_protocol::Id128, generation: u64) -> bool {
        self.offer.id == offer_id && self.offer.generation == generation
    }
}

impl AcceptedChunk {
    fn from_chunk(item_index: usize, chunk: &BlobChunk) -> Self {
        Self {
            item_index,
            offset_bytes: chunk.offset_bytes,
            payload_len: chunk.payload.len(),
            final_chunk: chunk.final_chunk,
            payload_hash: Sha256::digest(&chunk.payload).into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };
    use viewflow_protocol::{DragItem, DragOperation, Id128};

    fn offer(path: &str, bytes: u64) -> DragOffer {
        DragOffer {
            id: Id128(7),
            generation: 1,
            source_device: Id128(1),
            target_device: Id128(2),
            operation: DragOperation::Copy,
            items: vec![DragItem {
                relative_path: path.into(),
                size_bytes: bytes,
                content_hash: None,
            }],
        }
    }
    fn temp() -> PathBuf {
        std::env::temp_dir().join(format!(
            "viewflow-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    #[test]
    fn owner_only_tree_dacl_is_protected_and_inherited() {
        assert_eq!(
            owner_only_tree_sddl("S-1-5-21-1-2-3-4"),
            "O:S-1-5-21-1-2-3-4D:P(A;OICI;FA;;;S-1-5-21-1-2-3-4)"
        );
    }

    #[test]
    fn writes_contiguous_chunk_and_completes() {
        let parent = temp();
        fs::create_dir(&parent).unwrap();
        let mut rx = InboundFileTransfer::accept(&parent, 1, offer("a/b.txt", 3)).unwrap();
        assert!(
            rx.push(&BlobChunk {
                transfer_id: Id128(7),
                item_index: 0,
                offset_bytes: 0,
                final_chunk: true,
                payload: Bytes::from_static(b"abc")
            })
            .unwrap()
            .is_some()
        );
        assert_eq!(
            fs::read(rx.root.join("item-00000000.part")).unwrap(),
            b"abc"
        );
        fs::remove_dir_all(parent).unwrap();
    }

    #[test]
    fn replays_accepted_chunks_without_rewriting_or_advancing_completion() {
        let parent = temp();
        fs::create_dir(&parent).unwrap();
        let mut rx = InboundFileTransfer::accept(&parent, 1, offer("x", 6)).unwrap();
        let first = BlobChunk {
            transfer_id: Id128(7),
            item_index: 0,
            offset_bytes: 0,
            final_chunk: false,
            payload: Bytes::from_static(b"abc"),
        };
        let last = BlobChunk {
            transfer_id: Id128(7),
            item_index: 0,
            offset_bytes: 3,
            final_chunk: true,
            payload: Bytes::from_static(b"def"),
        };

        assert_eq!(rx.push(&first).unwrap(), None);
        assert_eq!(rx.push(&first).unwrap(), None);
        let completion = rx.push(&last).unwrap().unwrap();
        assert_eq!(rx.push(&last).unwrap(), Some(completion.clone()));
        assert_eq!(rx.push(&first).unwrap(), Some(completion));
        assert_eq!(
            fs::read(rx.root.join("item-00000000.part")).unwrap(),
            b"abcdef"
        );
        drop(rx);
        fs::remove_dir_all(parent).unwrap();
    }

    #[test]
    fn rejects_altered_or_overlapping_chunk_replays() {
        let parent = temp();
        fs::create_dir(&parent).unwrap();
        let mut rx = InboundFileTransfer::accept(&parent, 1, offer("x", 6)).unwrap();
        assert_eq!(
            rx.push(&BlobChunk {
                transfer_id: Id128(7),
                item_index: 0,
                offset_bytes: 0,
                final_chunk: false,
                payload: Bytes::from_static(b"abc"),
            }),
            Ok(None)
        );
        for chunk in [
            BlobChunk {
                transfer_id: Id128(7),
                item_index: 0,
                offset_bytes: 0,
                final_chunk: false,
                payload: Bytes::from_static(b"abd"),
            },
            BlobChunk {
                transfer_id: Id128(7),
                item_index: 0,
                offset_bytes: 1,
                final_chunk: false,
                payload: Bytes::from_static(b"bc"),
            },
        ] {
            assert_eq!(rx.push(&chunk), Err(TransferError::InvalidChunkOffset));
        }
        drop(rx);
        fs::remove_dir_all(parent).unwrap();
    }

    #[test]
    fn rejects_traversal_and_noncontiguous_chunks() {
        let parent = temp();
        fs::create_dir(&parent).unwrap();
        assert!(matches!(
            InboundFileTransfer::accept(&parent, 1, offer("../x", 1)),
            Err(TransferError::InvalidRelativePath)
        ));
        let mut rx = InboundFileTransfer::accept(&parent, 1, offer("x", 2)).unwrap();
        assert_eq!(
            rx.push(&BlobChunk {
                transfer_id: Id128(7),
                item_index: 0,
                offset_bytes: 1,
                final_chunk: false,
                payload: Bytes::from_static(b"x")
            }),
            Err(TransferError::InvalidChunkOffset)
        );
        fs::remove_dir_all(parent).unwrap();
    }

    #[test]
    fn rejects_incorrect_final_flag_and_cleans_partial_tree_on_drop() {
        let parent = temp();
        fs::create_dir(&parent).unwrap();
        let root = {
            let mut rx = InboundFileTransfer::accept(&parent, 1, offer("x", 2)).unwrap();
            let root = rx.root.clone();
            assert_eq!(
                rx.push(&BlobChunk {
                    transfer_id: Id128(7),
                    item_index: 0,
                    offset_bytes: 0,
                    final_chunk: true,
                    payload: Bytes::from_static(b"x")
                }),
                Err(TransferError::TransferIncomplete)
            );
            assert!(root.exists());
            root
        };
        assert!(!root.exists());
        fs::remove_dir_all(parent).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn temporary_root_is_owner_only() {
        use std::os::unix::fs::PermissionsExt;

        let parent = temp();
        fs::create_dir(&parent).unwrap();
        let rx = InboundFileTransfer::accept(&parent, 1, offer("x", 1)).unwrap();
        assert_eq!(
            fs::metadata(&rx.root).unwrap().permissions().mode() & 0o777,
            0o700
        );
        drop(rx);
        fs::remove_dir_all(parent).unwrap();
    }

    #[test]
    fn zero_length_offer_completes_without_a_blob_chunk() {
        let parent = temp();
        fs::create_dir(&parent).unwrap();
        let mut rx = InboundFileTransfer::accept(&parent, 1, offer("empty", 0)).unwrap();
        let completion = rx.completion_if_ready().unwrap().unwrap();
        assert_eq!(completion.item_results[0].bytes_received, 0);
        assert_eq!(
            completion.item_results[0].content_hash,
            Some(Sha256::digest([]).into())
        );
        drop(rx);
        fs::remove_dir_all(parent).unwrap();
    }

    #[test]
    fn global_quota_bounds_concurrent_connections() {
        let quota = Arc::new(Semaphore::new(GLOBAL_QUOTA_UNITS));
        let first = Arc::clone(&quota)
            .try_acquire_many_owned(quota_units(MAX_TOTAL_BYTES).unwrap())
            .unwrap();
        let second = Arc::clone(&quota)
            .try_acquire_many_owned(quota_units(MAX_TOTAL_BYTES).unwrap())
            .unwrap();
        assert!(
            Arc::clone(&quota)
                .try_acquire_many_owned(quota_units(1).unwrap())
                .is_err()
        );
        drop((first, second));
        assert_eq!(quota.available_permits(), GLOBAL_QUOTA_UNITS);
    }
}
