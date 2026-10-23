//! Clipboard and file-drag transfer state machines.

use std::collections::HashSet;

use viewflow_protocol::{
    ClipboardOffer, DragAccept, DragComplete, DragCompletionStatus, DragItem, DragOffer,
    DragProgress, Id128,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransferError {
    StaleGeneration,
    GenerationMismatch,
    InvalidInitialSequence,
    OutOfOrderSequence,
    UnknownOffer,
    InvalidState,
    EmptyOffer,
    InvalidFlavor,
    DuplicateFlavor,
    InvalidRelativePath,
    ConflictingRelativePath,
    TotalSizeOverflow,
    QuotaExceeded,
    UnknownItem,
    EmptyChunk,
    InvalidChunkOffset,
    ItemSizeExceeded,
    TransferIncomplete,
    HashCountMismatch,
    HashMissing,
    HashMismatch,
    InvalidOperation,
    InvalidDestination,
    ProgressMismatch,
    DuplicateItemResult,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ClipboardTransferState {
    Offered,
    Accepted { flavor: String },
    Completed,
    Cancelled,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClipboardTransfer {
    pub generation: u64,
    pub offer: ClipboardOffer,
    pub state: ClipboardTransferState,
    last_sequence: u64,
}

impl ClipboardTransfer {
    #[must_use]
    pub fn last_sequence(&self) -> u64 {
        self.last_sequence
    }
}

#[derive(Debug, Default)]
pub struct ClipboardTransfers {
    latest_generation: u64,
    current: Option<ClipboardTransfer>,
}

impl ClipboardTransfers {
    /// Applies a protocol clipboard offer using its embedded generation.
    ///
    /// # Errors
    ///
    /// Returns the same validation errors as [`Self::offer`].
    pub fn offer_control(
        &mut self,
        sequence: u64,
        offer: ClipboardOffer,
    ) -> Result<(), TransferError> {
        self.offer(offer.generation, sequence, offer)
    }

    /// Installs a new clipboard offer, superseding any older generation.
    ///
    /// # Errors
    ///
    /// Rejects stale generations, zero initial sequences, empty offers,
    /// duplicate flavor names, and flavors with an empty name.
    pub fn offer(
        &mut self,
        generation: u64,
        sequence: u64,
        offer: ClipboardOffer,
    ) -> Result<(), TransferError> {
        if generation <= self.latest_generation {
            return Err(TransferError::StaleGeneration);
        }
        if generation != offer.generation {
            return Err(TransferError::GenerationMismatch);
        }
        if sequence == 0 {
            return Err(TransferError::InvalidInitialSequence);
        }
        validate_clipboard_offer(&offer)?;

        self.latest_generation = generation;
        self.current = Some(ClipboardTransfer {
            generation,
            offer,
            state: ClipboardTransferState::Offered,
            last_sequence: sequence,
        });
        Ok(())
    }

    /// Accepts one advertised flavor.
    ///
    /// # Errors
    ///
    /// Rejects an unknown offer, stale or out-of-order messages, a flavor not
    /// present in the offer, or a transfer that is no longer offered.
    pub fn accept(
        &mut self,
        generation: u64,
        sequence: u64,
        offer_id: Id128,
        flavor: &str,
    ) -> Result<(), TransferError> {
        let transfer = self.current_for(generation, sequence, offer_id)?;
        if transfer.state != ClipboardTransferState::Offered {
            return Err(TransferError::InvalidState);
        }
        if !transfer
            .offer
            .flavors
            .iter()
            .any(|candidate| candidate.name == flavor)
        {
            return Err(TransferError::InvalidFlavor);
        }
        transfer.state = ClipboardTransferState::Accepted {
            flavor: flavor.to_owned(),
        };
        transfer.last_sequence = sequence;
        Ok(())
    }

    /// Marks the accepted clipboard payload complete.
    ///
    /// # Errors
    ///
    /// Rejects stale, out-of-order, unknown, or non-accepted transfers.
    pub fn complete(
        &mut self,
        generation: u64,
        sequence: u64,
        offer_id: Id128,
    ) -> Result<(), TransferError> {
        let transfer = self.current_for(generation, sequence, offer_id)?;
        if !matches!(transfer.state, ClipboardTransferState::Accepted { .. }) {
            return Err(TransferError::InvalidState);
        }
        transfer.state = ClipboardTransferState::Completed;
        transfer.last_sequence = sequence;
        Ok(())
    }

    /// Cancels an offered or accepted clipboard transfer.
    ///
    /// # Errors
    ///
    /// Rejects stale, out-of-order, unknown, or already-terminal transfers.
    pub fn cancel(
        &mut self,
        generation: u64,
        sequence: u64,
        offer_id: Id128,
    ) -> Result<(), TransferError> {
        let transfer = self.current_for(generation, sequence, offer_id)?;
        if matches!(
            transfer.state,
            ClipboardTransferState::Completed | ClipboardTransferState::Cancelled
        ) {
            return Err(TransferError::InvalidState);
        }
        transfer.state = ClipboardTransferState::Cancelled;
        transfer.last_sequence = sequence;
        Ok(())
    }

    #[must_use]
    pub fn current(&self) -> Option<&ClipboardTransfer> {
        self.current.as_ref()
    }

    fn current_for(
        &mut self,
        generation: u64,
        sequence: u64,
        offer_id: Id128,
    ) -> Result<&mut ClipboardTransfer, TransferError> {
        let transfer = self.current.as_mut().ok_or(TransferError::UnknownOffer)?;
        if transfer.offer.id != offer_id {
            return Err(TransferError::UnknownOffer);
        }
        validate_generation_and_sequence(
            transfer.generation,
            transfer.last_sequence,
            generation,
            sequence,
        )?;
        Ok(transfer)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DragTransferState {
    Offered,
    Accepted,
    Completed,
    Cancelled,
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DragTransfer {
    pub generation: u64,
    pub offer: DragOffer,
    pub state: DragTransferState,
    total_size_bytes: u64,
    received_bytes: Vec<u64>,
    observed_hashes: Vec<Option<[u8; 32]>>,
    failure_message: Option<String>,
    last_sequence: u64,
}

impl DragTransfer {
    #[must_use]
    pub fn total_size_bytes(&self) -> u64 {
        self.total_size_bytes
    }

    #[must_use]
    pub fn total_received_bytes(&self) -> u64 {
        self.received_bytes.iter().sum()
    }

    #[must_use]
    pub fn item_received_bytes(&self, item_index: usize) -> Option<u64> {
        self.received_bytes.get(item_index).copied()
    }

    #[must_use]
    pub fn observed_hash(&self, item_index: usize) -> Option<[u8; 32]> {
        self.observed_hashes.get(item_index).copied().flatten()
    }

    #[must_use]
    pub fn failure_message(&self) -> Option<&str> {
        self.failure_message.as_deref()
    }

    #[must_use]
    pub fn last_sequence(&self) -> u64 {
        self.last_sequence
    }
}

#[derive(Debug, Default)]
pub struct DragTransfers {
    latest_generation: u64,
    current: Option<DragTransfer>,
}

impl DragTransfers {
    /// Applies a protocol drag offer using its embedded generation.
    ///
    /// # Errors
    ///
    /// Returns the same validation errors as [`Self::offer`].
    pub fn offer_control(&mut self, sequence: u64, offer: DragOffer) -> Result<(), TransferError> {
        self.offer(offer.generation, sequence, offer)
    }

    /// Installs a new file-drag offer after validating all destination-relative
    /// paths and aggregate size metadata.
    ///
    /// # Errors
    ///
    /// Rejects stale generations, zero initial sequences, active transfers,
    /// unsafe or colliding paths, empty offers, and aggregate size overflow.
    pub fn offer(
        &mut self,
        generation: u64,
        sequence: u64,
        offer: DragOffer,
    ) -> Result<(), TransferError> {
        if generation <= self.latest_generation {
            return Err(TransferError::StaleGeneration);
        }
        if generation != offer.generation {
            return Err(TransferError::GenerationMismatch);
        }
        if sequence == 0 {
            return Err(TransferError::InvalidInitialSequence);
        }
        if self.current.as_ref().is_some_and(|current| {
            matches!(
                current.state,
                DragTransferState::Offered | DragTransferState::Accepted
            )
        }) {
            return Err(TransferError::InvalidState);
        }
        let total_size_bytes = validate_drag_items(&offer.items)?;
        let item_count = offer.items.len();
        self.latest_generation = generation;
        self.current = Some(DragTransfer {
            generation,
            offer,
            state: DragTransferState::Offered,
            total_size_bytes,
            received_bytes: vec![0; item_count],
            observed_hashes: vec![None; item_count],
            failure_message: None,
            last_sequence: sequence,
        });
        Ok(())
    }

    /// Accepts the complete drag offer.
    ///
    /// # Errors
    ///
    /// Rejects stale, out-of-order, unknown, or non-offered transfers.
    pub fn accept(
        &mut self,
        generation: u64,
        sequence: u64,
        offer_id: Id128,
    ) -> Result<(), TransferError> {
        let transfer = self.current_for(generation, sequence, offer_id)?;
        if transfer.state != DragTransferState::Offered {
            return Err(TransferError::InvalidState);
        }
        transfer.state = DragTransferState::Accepted;
        transfer.last_sequence = sequence;
        Ok(())
    }

    /// Applies a protocol accept message.
    ///
    /// # Errors
    ///
    /// In addition to [`Self::accept`] errors, rejects an operation that differs
    /// from the offer and an empty or control-character destination token.
    pub fn accept_control(
        &mut self,
        sequence: u64,
        accept: &DragAccept,
    ) -> Result<(), TransferError> {
        let transfer = self.current.as_ref().ok_or(TransferError::UnknownOffer)?;
        if transfer.offer.id != accept.offer_id {
            return Err(TransferError::UnknownOffer);
        }
        if transfer.offer.operation != accept.operation {
            return Err(TransferError::InvalidOperation);
        }
        if accept.destination_token.trim().is_empty()
            || accept.destination_token.chars().any(char::is_control)
        {
            return Err(TransferError::InvalidDestination);
        }
        self.accept(accept.generation, sequence, accept.offer_id)
    }

    /// Records a contiguous file chunk without retaining payload bytes.
    ///
    /// `offset` must equal the bytes already received for that item. This keeps
    /// retry/deduplication decisions at the reliable transport boundary and
    /// prevents sparse-file or overlap ambiguity in the core state machine.
    ///
    /// # Errors
    ///
    /// Rejects stale or out-of-order messages, unknown items, empty chunks,
    /// noncontiguous offsets, and chunks exceeding the advertised item size.
    pub fn chunk_progress(
        &mut self,
        generation: u64,
        sequence: u64,
        offer_id: Id128,
        item_index: usize,
        offset: u64,
        chunk_size_bytes: u64,
    ) -> Result<(), TransferError> {
        let transfer = self.current_for(generation, sequence, offer_id)?;
        if transfer.state != DragTransferState::Accepted {
            return Err(TransferError::InvalidState);
        }
        if chunk_size_bytes == 0 {
            return Err(TransferError::EmptyChunk);
        }
        let item = transfer
            .offer
            .items
            .get(item_index)
            .ok_or(TransferError::UnknownItem)?;
        let received = transfer
            .received_bytes
            .get_mut(item_index)
            .ok_or(TransferError::UnknownItem)?;
        if offset != *received {
            return Err(TransferError::InvalidChunkOffset);
        }
        let end = offset
            .checked_add(chunk_size_bytes)
            .ok_or(TransferError::ItemSizeExceeded)?;
        if end > item.size_bytes {
            return Err(TransferError::ItemSizeExceeded);
        }
        *received = end;
        transfer.last_sequence = sequence;
        Ok(())
    }

    /// Applies a protocol per-item progress message and cross-checks its
    /// aggregate counters against locally admitted chunks.
    ///
    /// # Errors
    ///
    /// In addition to [`Self::chunk_progress`] errors, rejects inconsistent
    /// aggregate or advertised total byte counts.
    pub fn progress_control(
        &mut self,
        sequence: u64,
        progress: DragProgress,
    ) -> Result<(), TransferError> {
        let transfer = self.current.as_ref().ok_or(TransferError::UnknownOffer)?;
        if transfer.offer.id != progress.offer_id {
            return Err(TransferError::UnknownOffer);
        }
        let expected_total = transfer
            .total_received_bytes()
            .checked_add(progress.chunk_size_bytes)
            .ok_or(TransferError::ProgressMismatch)?;
        if progress.total_bytes != transfer.total_size_bytes
            || progress.bytes_transferred != expected_total
        {
            return Err(TransferError::ProgressMismatch);
        }
        let item_index =
            usize::try_from(progress.item_index).map_err(|_| TransferError::UnknownItem)?;
        self.chunk_progress(
            progress.generation,
            sequence,
            progress.offer_id,
            item_index,
            progress.offset_bytes,
            progress.chunk_size_bytes,
        )
    }

    /// Verifies final byte counts and observed hashes, then commits the drag.
    ///
    /// The I/O layer computes `observed_hashes`; this state machine compares
    /// them with the immutable hashes advertised by the sender.
    ///
    /// # Errors
    ///
    /// Rejects incomplete transfers, missing or mismatched required hashes,
    /// and stale, out-of-order, unknown, or non-accepted transfers.
    pub fn complete(
        &mut self,
        generation: u64,
        sequence: u64,
        offer_id: Id128,
        observed_hashes: Vec<Option<[u8; 32]>>,
    ) -> Result<(), TransferError> {
        let transfer = self.current_for(generation, sequence, offer_id)?;
        if transfer.state != DragTransferState::Accepted {
            return Err(TransferError::InvalidState);
        }
        if observed_hashes.len() != transfer.offer.items.len() {
            return Err(TransferError::HashCountMismatch);
        }
        if transfer
            .offer
            .items
            .iter()
            .zip(&transfer.received_bytes)
            .any(|(item, received)| item.size_bytes != *received)
        {
            return Err(TransferError::TransferIncomplete);
        }
        for (item, observed) in transfer.offer.items.iter().zip(&observed_hashes) {
            if let Some(expected) = item.content_hash {
                let actual = observed.ok_or(TransferError::HashMissing)?;
                if actual != expected {
                    return Err(TransferError::HashMismatch);
                }
            }
        }
        transfer.observed_hashes = observed_hashes;
        transfer.state = DragTransferState::Completed;
        transfer.last_sequence = sequence;
        Ok(())
    }

    /// Applies a protocol terminal message, validating one final result for
    /// every advertised item on successful completion.
    ///
    /// # Errors
    ///
    /// Rejects missing, duplicate, out-of-range, size-inconsistent, or
    /// hash-inconsistent item results and all ordinary sequencing errors.
    pub fn complete_control(
        &mut self,
        sequence: u64,
        completion: DragComplete,
    ) -> Result<(), TransferError> {
        match completion.status {
            DragCompletionStatus::Cancelled => {
                self.cancel(completion.generation, sequence, completion.offer_id)
            }
            DragCompletionStatus::Failed => self.fail(
                completion.generation,
                sequence,
                completion.offer_id,
                completion.error_message,
            ),
            DragCompletionStatus::Completed => {
                let transfer = self.current.as_ref().ok_or(TransferError::UnknownOffer)?;
                if transfer.offer.id != completion.offer_id {
                    return Err(TransferError::UnknownOffer);
                }
                if completion.item_results.len() != transfer.offer.items.len() {
                    return Err(TransferError::HashCountMismatch);
                }
                let mut observed_hashes = vec![None; transfer.offer.items.len()];
                let mut seen = vec![false; transfer.offer.items.len()];
                for result in completion.item_results {
                    let index = usize::try_from(result.item_index)
                        .map_err(|_| TransferError::UnknownItem)?;
                    let item = transfer
                        .offer
                        .items
                        .get(index)
                        .ok_or(TransferError::UnknownItem)?;
                    let received = transfer
                        .received_bytes
                        .get(index)
                        .ok_or(TransferError::UnknownItem)?;
                    if seen[index] {
                        return Err(TransferError::DuplicateItemResult);
                    }
                    if result.bytes_received != item.size_bytes
                        || result.bytes_received != *received
                    {
                        return Err(TransferError::TransferIncomplete);
                    }
                    seen[index] = true;
                    observed_hashes[index] = result.content_hash;
                }
                self.complete(
                    completion.generation,
                    sequence,
                    completion.offer_id,
                    observed_hashes,
                )
            }
        }
    }

    /// Cancels an offered or accepted file drag.
    ///
    /// # Errors
    ///
    /// Rejects stale, out-of-order, unknown, or terminal transfers.
    pub fn cancel(
        &mut self,
        generation: u64,
        sequence: u64,
        offer_id: Id128,
    ) -> Result<(), TransferError> {
        let transfer = self.current_for(generation, sequence, offer_id)?;
        if matches!(
            transfer.state,
            DragTransferState::Completed | DragTransferState::Cancelled | DragTransferState::Failed
        ) {
            return Err(TransferError::InvalidState);
        }
        transfer.state = DragTransferState::Cancelled;
        transfer.failure_message = None;
        transfer.last_sequence = sequence;
        Ok(())
    }

    fn fail(
        &mut self,
        generation: u64,
        sequence: u64,
        offer_id: Id128,
        message: Option<String>,
    ) -> Result<(), TransferError> {
        let transfer = self.current_for(generation, sequence, offer_id)?;
        if matches!(
            transfer.state,
            DragTransferState::Completed | DragTransferState::Cancelled | DragTransferState::Failed
        ) {
            return Err(TransferError::InvalidState);
        }
        transfer.state = DragTransferState::Failed;
        transfer.failure_message = message;
        transfer.last_sequence = sequence;
        Ok(())
    }

    #[must_use]
    pub fn current(&self) -> Option<&DragTransfer> {
        self.current.as_ref()
    }

    fn current_for(
        &mut self,
        generation: u64,
        sequence: u64,
        offer_id: Id128,
    ) -> Result<&mut DragTransfer, TransferError> {
        let transfer = self.current.as_mut().ok_or(TransferError::UnknownOffer)?;
        if transfer.offer.id != offer_id {
            return Err(TransferError::UnknownOffer);
        }
        validate_generation_and_sequence(
            transfer.generation,
            transfer.last_sequence,
            generation,
            sequence,
        )?;
        Ok(transfer)
    }
}

fn validate_generation_and_sequence(
    expected_generation: u64,
    last_sequence: u64,
    generation: u64,
    sequence: u64,
) -> Result<(), TransferError> {
    if generation != expected_generation {
        return Err(TransferError::StaleGeneration);
    }
    if sequence <= last_sequence {
        return Err(TransferError::OutOfOrderSequence);
    }
    Ok(())
}

fn validate_clipboard_offer(offer: &ClipboardOffer) -> Result<(), TransferError> {
    if offer.flavors.is_empty() {
        return Err(TransferError::EmptyOffer);
    }
    let mut flavors = HashSet::with_capacity(offer.flavors.len());
    for flavor in &offer.flavors {
        if flavor.name.trim().is_empty() || flavor.name.chars().any(char::is_control) {
            return Err(TransferError::InvalidFlavor);
        }
        if !flavors.insert(flavor.name.to_ascii_lowercase()) {
            return Err(TransferError::DuplicateFlavor);
        }
    }
    Ok(())
}

fn validate_drag_items(items: &[DragItem]) -> Result<u64, TransferError> {
    if items.is_empty() {
        return Err(TransferError::EmptyOffer);
    }
    let mut total = 0_u64;
    let mut paths = Vec::with_capacity(items.len());
    for item in items {
        let normalized = normalize_relative_path(&item.relative_path)?;
        if paths.iter().any(|existing: &String| {
            existing == &normalized
                || existing
                    .strip_prefix(&normalized)
                    .is_some_and(|rest| rest.starts_with('/'))
                || normalized
                    .strip_prefix(existing)
                    .is_some_and(|rest| rest.starts_with('/'))
        }) {
            return Err(TransferError::ConflictingRelativePath);
        }
        paths.push(normalized);
        total = total
            .checked_add(item.size_bytes)
            .ok_or(TransferError::TotalSizeOverflow)?;
    }
    Ok(total)
}

fn normalize_relative_path(path: &str) -> Result<String, TransferError> {
    if path.is_empty()
        || path.starts_with(['/', '\\'])
        || path
            .chars()
            .any(|character| character.is_control() || character == ':')
    {
        return Err(TransferError::InvalidRelativePath);
    }
    let mut normalized = String::with_capacity(path.len());
    for (index, component) in path.split(['/', '\\']).enumerate() {
        if component.is_empty() || component == "." || component == ".." {
            return Err(TransferError::InvalidRelativePath);
        }
        if index != 0 {
            normalized.push('/');
        }
        for character in component.chars().flat_map(char::to_lowercase) {
            normalized.push(character);
        }
    }
    Ok(normalized)
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::{ClipboardFlavor, DragItemResult, DragOperation};

    fn clipboard_offer(id: u128, generation: u64) -> ClipboardOffer {
        ClipboardOffer {
            id: Id128(id),
            owner: Id128(id + 100),
            generation,
            flavors: vec![
                ClipboardFlavor {
                    name: "text/plain;charset=utf-8".to_owned(),
                    size_bytes: 5,
                },
                ClipboardFlavor {
                    name: "text/html".to_owned(),
                    size_bytes: 12,
                },
            ],
        }
    }

    fn drag_offer(id: u128, generation: u64) -> DragOffer {
        DragOffer {
            id: Id128(id),
            generation,
            source_device: Id128(1),
            target_device: Id128(2),
            operation: DragOperation::Copy,
            items: vec![
                DragItem {
                    relative_path: "reports/one.txt".to_owned(),
                    size_bytes: 4,
                    content_hash: Some([1; 32]),
                },
                DragItem {
                    relative_path: "two.bin".to_owned(),
                    size_bytes: 2,
                    content_hash: None,
                },
            ],
        }
    }

    #[test]
    fn clipboard_offer_accept_complete_is_strictly_sequenced() {
        let mut transfers = ClipboardTransfers::default();
        transfers.offer(1, 1, clipboard_offer(10, 1)).unwrap();
        assert_eq!(
            transfers.accept(1, 1, Id128(10), "text/html"),
            Err(TransferError::OutOfOrderSequence)
        );
        transfers
            .accept(1, 3, Id128(10), "text/plain;charset=utf-8")
            .unwrap();
        transfers.complete(1, 4, Id128(10)).unwrap();
        assert_eq!(
            transfers.current().map(|transfer| &transfer.state),
            Some(&ClipboardTransferState::Completed)
        );
    }

    #[test]
    fn newer_clipboard_offer_supersedes_older_offer() {
        let mut transfers = ClipboardTransfers::default();
        transfers.offer(5, 5, clipboard_offer(10, 5)).unwrap();
        transfers.offer(6, 6, clipboard_offer(11, 6)).unwrap();
        assert_eq!(
            transfers.accept(5, 1, Id128(10), "text/html"),
            Err(TransferError::UnknownOffer)
        );
        assert_eq!(
            transfers.current().map(|transfer| transfer.offer.id),
            Some(Id128(11))
        );
    }

    #[test]
    fn clipboard_rejects_duplicate_case_insensitive_flavors() {
        let mut offer = clipboard_offer(10, 1);
        offer.flavors[1].name = "TEXT/PLAIN;CHARSET=UTF-8".to_owned();
        let mut transfers = ClipboardTransfers::default();
        assert_eq!(
            transfers.offer(1, 1, offer),
            Err(TransferError::DuplicateFlavor)
        );
    }

    #[test]
    fn drag_rejects_cross_platform_path_traversal_and_collisions() {
        for unsafe_path in [
            "../secret",
            "safe/../secret",
            "/etc/passwd",
            r"C:\\Windows\\file",
            r"\\server\\share",
            "safe//file",
        ] {
            let mut offer = drag_offer(10, 1);
            offer.items[0].relative_path = unsafe_path.to_owned();
            let mut transfers = DragTransfers::default();
            assert_eq!(
                transfers.offer(1, 1, offer),
                Err(TransferError::InvalidRelativePath),
                "path {unsafe_path:?} should be rejected"
            );
        }

        let mut offer = drag_offer(10, 1);
        offer.items[1].relative_path = "REPORTS/ONE.TXT".to_owned();
        let mut transfers = DragTransfers::default();
        assert_eq!(
            transfers.offer(1, 1, offer),
            Err(TransferError::ConflictingRelativePath)
        );
    }

    #[test]
    fn drag_tracks_interleaved_contiguous_chunks_and_hashes() {
        let mut transfers = DragTransfers::default();
        transfers.offer(1, 1, drag_offer(10, 1)).unwrap();
        transfers.accept(1, 2, Id128(10)).unwrap();
        transfers.chunk_progress(1, 3, Id128(10), 0, 0, 2).unwrap();
        transfers.chunk_progress(1, 4, Id128(10), 1, 0, 2).unwrap();
        transfers.chunk_progress(1, 5, Id128(10), 0, 2, 2).unwrap();
        transfers
            .complete(1, 6, Id128(10), vec![Some([1; 32]), Some([9; 32])])
            .unwrap();
        let transfer = transfers.current().unwrap();
        assert_eq!(transfer.state, DragTransferState::Completed);
        assert_eq!(transfer.total_size_bytes(), 6);
        assert_eq!(transfer.total_received_bytes(), 6);
        assert_eq!(transfer.observed_hash(0), Some([1; 32]));
    }

    #[test]
    fn rejected_drag_chunk_does_not_consume_sequence() {
        let mut transfers = DragTransfers::default();
        transfers.offer(1, 1, drag_offer(10, 1)).unwrap();
        transfers.accept(1, 2, Id128(10)).unwrap();
        assert_eq!(
            transfers.chunk_progress(1, 3, Id128(10), 0, 1, 2),
            Err(TransferError::InvalidChunkOffset)
        );
        transfers.chunk_progress(1, 3, Id128(10), 0, 0, 2).unwrap();
    }

    #[test]
    fn drag_completion_requires_all_bytes_and_declared_hashes() {
        let mut transfers = DragTransfers::default();
        transfers.offer(1, 1, drag_offer(10, 1)).unwrap();
        transfers.accept(1, 2, Id128(10)).unwrap();
        assert_eq!(
            transfers.complete(1, 3, Id128(10), vec![Some([1; 32]), None]),
            Err(TransferError::TransferIncomplete)
        );
        transfers.chunk_progress(1, 3, Id128(10), 0, 0, 4).unwrap();
        transfers.chunk_progress(1, 4, Id128(10), 1, 0, 2).unwrap();
        assert_eq!(
            transfers.complete(1, 5, Id128(10), vec![None, None]),
            Err(TransferError::HashMissing)
        );
        assert_eq!(
            transfers.complete(1, 5, Id128(10), vec![Some([2; 32]), None]),
            Err(TransferError::HashMismatch)
        );
        transfers
            .complete(1, 5, Id128(10), vec![Some([1; 32]), None])
            .unwrap();
    }

    #[test]
    fn active_drag_requires_explicit_cancel_before_new_offer() {
        let mut transfers = DragTransfers::default();
        transfers.offer(1, 1, drag_offer(10, 1)).unwrap();
        assert_eq!(
            transfers.offer(2, 2, drag_offer(11, 2)),
            Err(TransferError::InvalidState)
        );
        transfers.cancel(1, 2, Id128(10)).unwrap();
        transfers.offer(2, 3, drag_offer(11, 2)).unwrap();
    }

    #[test]
    fn protocol_drag_controls_cross_check_aggregate_and_item_results() {
        let mut transfers = DragTransfers::default();
        transfers.offer_control(1, drag_offer(10, 1)).unwrap();
        transfers
            .accept_control(
                2,
                &DragAccept {
                    offer_id: Id128(10),
                    generation: 1,
                    operation: DragOperation::Copy,
                    destination_token: "portal:document/42".to_owned(),
                },
            )
            .unwrap();
        assert_eq!(
            transfers.progress_control(
                3,
                DragProgress {
                    offer_id: Id128(10),
                    generation: 1,
                    bytes_transferred: 3,
                    total_bytes: 6,
                    item_index: 0,
                    offset_bytes: 0,
                    chunk_size_bytes: 2,
                    chunk_hash: Some([7; 32]),
                }
            ),
            Err(TransferError::ProgressMismatch)
        );
        transfers
            .progress_control(
                3,
                DragProgress {
                    offer_id: Id128(10),
                    generation: 1,
                    bytes_transferred: 4,
                    total_bytes: 6,
                    item_index: 0,
                    offset_bytes: 0,
                    chunk_size_bytes: 4,
                    chunk_hash: Some([7; 32]),
                },
            )
            .unwrap();
        transfers
            .progress_control(
                4,
                DragProgress {
                    offer_id: Id128(10),
                    generation: 1,
                    bytes_transferred: 6,
                    total_bytes: 6,
                    item_index: 1,
                    offset_bytes: 0,
                    chunk_size_bytes: 2,
                    chunk_hash: None,
                },
            )
            .unwrap();
        transfers
            .complete_control(
                5,
                DragComplete {
                    offer_id: Id128(10),
                    generation: 1,
                    status: DragCompletionStatus::Completed,
                    error_message: None,
                    item_results: vec![
                        DragItemResult {
                            item_index: 1,
                            bytes_received: 2,
                            content_hash: Some([9; 32]),
                        },
                        DragItemResult {
                            item_index: 0,
                            bytes_received: 4,
                            content_hash: Some([1; 32]),
                        },
                    ],
                },
            )
            .unwrap();
        assert_eq!(
            transfers.current().map(|transfer| transfer.state),
            Some(DragTransferState::Completed)
        );
    }

    #[test]
    fn protocol_failed_completion_preserves_failure_message() {
        let mut transfers = DragTransfers::default();
        transfers.offer_control(1, drag_offer(10, 1)).unwrap();
        transfers
            .complete_control(
                2,
                DragComplete {
                    offer_id: Id128(10),
                    generation: 1,
                    status: DragCompletionStatus::Failed,
                    error_message: Some("destination disconnected".to_owned()),
                    item_results: Vec::new(),
                },
            )
            .unwrap();
        let transfer = transfers.current().unwrap();
        assert_eq!(transfer.state, DragTransferState::Failed);
        assert_eq!(transfer.failure_message(), Some("destination disconnected"));
    }

    #[test]
    fn protocol_accept_validates_operation_and_destination_capability() {
        let mut transfers = DragTransfers::default();
        transfers.offer_control(1, drag_offer(10, 1)).unwrap();
        assert_eq!(
            transfers.accept_control(
                2,
                &DragAccept {
                    offer_id: Id128(10),
                    generation: 1,
                    operation: DragOperation::Move,
                    destination_token: "portal:document/42".to_owned(),
                }
            ),
            Err(TransferError::InvalidOperation)
        );
        assert_eq!(
            transfers.accept_control(
                2,
                &DragAccept {
                    offer_id: Id128(10),
                    generation: 1,
                    operation: DragOperation::Copy,
                    destination_token: String::new(),
                }
            ),
            Err(TransferError::InvalidDestination)
        );
    }
}
