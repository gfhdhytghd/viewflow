//! Bounded post-negotiation atlas metadata/media admission. This does not perform
//! the handshake, decode pixels, acknowledge presentation or authorize input.
use crate::media_runtime::EncodedFrame;
use viewflow_protocol::{AtlasFrame, AtlasTile, Id128};
use viewflow_transport::CodecFrameAdmission;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AtlasReceiverPolicy {
    pub stream_id: Id128,
    pub geometry_epoch: u64,
    pub config_generation: u64,
    pub width: u32,
    pub height: u32,
    pub max_tiles: usize,
    pub max_encoded_bytes: usize,
    pub max_age_ns: u64,
    pub max_future_ns: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AtlasAdmissionError {
    InvalidPolicy,
    InvalidManifest,
    WrongStream,
    Replay,
    LayoutConflict,
    SourceReplay,
    Expired,
    FutureTimestamp,
    MissingManifest,
    MediaMismatch,
    MissingAlpha,
    ByteLimit,
    KeyframeRequired,
}

/// Metadata and encoded bytes travel together to the decoder/proxy owner.
/// Successful admission is NOT successful decoding or presentation.
pub struct AdmittedAtlas {
    pub layout: AtlasFrame,
    pub media: EncodedFrame,
}

pub struct AtlasReceiver {
    policy: AtlasReceiverPolicy,
    observed: Option<AtlasFrame>,
    pending: Option<AtlasFrame>,
    delivered: Option<AtlasFrame>,
    finish_latest: bool,
}

impl AtlasReceiver {
    /// The connection owner must explicitly negotiate these exact stream
    /// parameters before constructing this component; ordinary coordinators
    /// deliberately reject atlas messages instead of constructing one implicitly.
    /// # Errors
    /// Rejects zero/unbounded resource and identity parameters.
    pub fn new(policy: AtlasReceiverPolicy) -> Result<Self, AtlasAdmissionError> {
        if policy.stream_id.0 == 0
            || policy.geometry_epoch == 0
            || policy.config_generation == 0
            || policy.width == 0
            || policy.height == 0
            || policy.width % 2 != 0
            || policy.height % 2 != 0
            || policy.max_tiles == 0
            || policy.max_tiles > 4096
            || policy.max_encoded_bytes == 0
            || policy.max_age_ns == 0
        {
            return Err(AtlasAdmissionError::InvalidPolicy);
        }
        Ok(Self {
            policy,
            observed: None,
            pending: None,
            delivered: None,
            finish_latest: false,
        })
    }

    /// Stage only the latest manifest from the authenticated reliable stream.
    /// A newer manifest replaces an older pending one, without extending time.
    /// # Errors
    /// Rejection does not overwrite the last valid pending layout.
    pub fn stage(&mut self, manifest: AtlasFrame, now: u64) -> Result<(), AtlasAdmissionError> {
        self.stage_with_expiry(manifest, now, false).map(|_| ())
    }

    /// V3 may discard a fully validated expired manifest before native decode.
    /// Observe its lineage but never install it as admissible pending media.
    pub(crate) fn stage_with_expiry(
        &mut self,
        manifest: AtlasFrame,
        now: u64,
        recover_expired: bool,
    ) -> Result<bool, AtlasAdmissionError> {
        manifest
            .validate()
            .map_err(|_| AtlasAdmissionError::InvalidManifest)?;
        if manifest.stream_id != self.policy.stream_id
            || manifest.geometry_epoch != self.policy.geometry_epoch
            || manifest.config_generation != self.policy.config_generation
            || manifest.width > self.policy.width
            || manifest.height > self.policy.height
            || manifest.tiles.len() > self.policy.max_tiles
        {
            return Err(AtlasAdmissionError::WrongStream);
        }
        if let Some(old) = &self.observed {
            validate_successor(old, &manifest)?;
        }
        self.finish_latest = recover_expired;
        self.fresh_for_delivery(&manifest, now)?;
        self.observed = Some(manifest.clone());
        self.pending = Some(manifest);
        Ok(false)
    }

    // The feedback protocol permits only one frame in flight. Its latest
    // manifest cannot be obsolete merely because it missed the latency target.
    pub(crate) fn fresh_for_delivery(
        &self,
        layout: &AtlasFrame,
        now: u64,
    ) -> Result<(), AtlasAdmissionError> {
        match self.fresh(layout, now) {
            Err(AtlasAdmissionError::Expired) if self.finish_latest => Ok(()),
            result => result,
        }
    }

    /// Pair with media already accepted by the ordinary assembler and codec
    /// session. Caller must recover the codec reference chain if it drops coded
    /// output; no error here is proof that a dependent P-frame can be decoded.
    /// # Errors
    /// Requires exact frame/clock/config identity, alpha, freshness and bounds.
    pub fn admit(
        &mut self,
        media: EncodedFrame,
        codec: CodecFrameAdmission,
        now: u64,
    ) -> Result<AdmittedAtlas, AtlasAdmissionError> {
        let layout = self
            .pending
            .as_ref()
            .ok_or(AtlasAdmissionError::MissingManifest)?;
        self.fresh_for_delivery(layout, now)?;
        let manifest = media.manifest;
        if manifest.window_id != layout.stream_id
            || manifest.frame_id != layout.frame_id
            || manifest.geometry_epoch != layout.geometry_epoch
            || manifest.source_submitted_ns != layout.source_submitted_ns
            || codec.frame_id != layout.frame_id
            || codec.config_generation != layout.config_generation
        {
            return Err(AtlasAdmissionError::MediaMismatch);
        }
        let alpha = media
            .alpha
            .as_ref()
            .filter(|alpha| !alpha.is_empty())
            .ok_or(AtlasAdmissionError::MissingAlpha)?;
        if media.color.is_empty()
            || media
                .color
                .len()
                .checked_add(alpha.len())
                .is_none_or(|size| size > self.policy.max_encoded_bytes)
        {
            return Err(AtlasAdmissionError::ByteLimit);
        }
        if self
            .delivered
            .as_ref()
            .is_none_or(|old| !same_layout(old, layout))
            && !codec.paired_keyframe
        {
            return Err(AtlasAdmissionError::KeyframeRequired);
        }
        let layout = self
            .pending
            .take()
            .ok_or(AtlasAdmissionError::MissingManifest)?;
        self.delivered = Some(layout.clone());
        Ok(AdmittedAtlas { layout, media })
    }

    pub(crate) fn remaining_budget_ns(
        &self,
        layout: &AtlasFrame,
        now: u64,
    ) -> Result<u64, AtlasAdmissionError> {
        self.fresh(layout, now)?;
        layout
            .source_submitted_ns
            .checked_add(self.policy.max_age_ns)
            .and_then(|deadline| deadline.checked_sub(now))
            .filter(|remaining| *remaining > 0)
            .ok_or(AtlasAdmissionError::Expired)
    }

    pub(crate) fn fresh(&self, layout: &AtlasFrame, now: u64) -> Result<(), AtlasAdmissionError> {
        // The atlas timestamp is the oldest tile; separately reject a tile from
        // the future even when some other tile makes the minimum look valid.
        if std::iter::once(layout.source_submitted_ns)
            .chain(layout.tiles.iter().map(|tile| tile.source_submitted_ns))
            .any(|timestamp| timestamp > now.saturating_add(self.policy.max_future_ns))
        {
            return Err(AtlasAdmissionError::FutureTimestamp);
        }
        if now.saturating_sub(layout.source_submitted_ns) >= self.policy.max_age_ns {
            return Err(AtlasAdmissionError::Expired);
        }
        Ok(())
    }
}

fn same_tile(a: &AtlasTile, b: &AtlasTile) -> bool {
    a.window_id == b.window_id
        && a.placement_generation == b.placement_generation
        && a.geometry_epoch == b.geometry_epoch
        && a.x == b.x
        && a.y == b.y
        && a.width == b.width
        && a.height == b.height
}

fn same_layout(a: &AtlasFrame, b: &AtlasFrame) -> bool {
    a.patches == b.patches
        && a.layout_revision == b.layout_revision
        && a.width == b.width
        && a.height == b.height
        && a.tiles.len() == b.tiles.len()
        && a.tiles.iter().zip(&b.tiles).all(|(a, b)| same_tile(a, b))
}

fn validate_successor(old: &AtlasFrame, new: &AtlasFrame) -> Result<(), AtlasAdmissionError> {
    if new.frame_id <= old.frame_id || new.source_submitted_ns <= old.source_submitted_ns {
        return Err(AtlasAdmissionError::Replay);
    }
    if new.layout_revision < old.layout_revision
        || (new.layout_revision == old.layout_revision && !same_layout(old, new))
    {
        return Err(AtlasAdmissionError::LayoutConflict);
    }
    for tile in &new.tiles {
        if let Some(previous) = old
            .tiles
            .iter()
            .find(|previous| previous.window_id == tile.window_id)
        {
            if tile.source_frame_id <= previous.source_frame_id
                || tile.source_submitted_ns <= previous.source_submitted_ns
                || tile.geometry_epoch < previous.geometry_epoch
            {
                return Err(AtlasAdmissionError::SourceReplay);
            }
            if !same_tile(previous, tile) && tile.placement_generation <= old.layout_revision {
                return Err(AtlasAdmissionError::LayoutConflict);
            }
        } else if tile.placement_generation <= old.layout_revision {
            return Err(AtlasAdmissionError::LayoutConflict);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    fn receiver() -> AtlasReceiver {
        AtlasReceiver::new(AtlasReceiverPolicy {
            stream_id: Id128(99),
            geometry_epoch: 1,
            config_generation: 1,
            width: 64,
            height: 64,
            max_tiles: 4,
            max_encoded_bytes: 16,
            max_age_ns: 50,
            max_future_ns: 2,
        })
        .unwrap()
    }
    fn layout(frame_id: u64) -> AtlasFrame {
        AtlasFrame {
            patches: None,
            color_keyframe: true,
            alpha_keyframe: true,
            desktop: None,
            stream_id: Id128(99),
            frame_id,
            geometry_epoch: 1,
            config_generation: 1,
            layout_revision: 1,
            width: 64,
            height: 64,
            source_submitted_ns: 100 + frame_id,
            tiles: vec![AtlasTile {
                window_id: Id128(1),
                placement_generation: 1,
                geometry_epoch: 7,
                source_frame_id: frame_id,
                source_submitted_ns: 100 + frame_id,
                x: 0,
                y: 0,
                width: 8,
                height: 8,
            }],
        }
    }
    fn media(frame_id: u64) -> EncodedFrame {
        EncodedFrame {
            manifest: viewflow_protocol::FrameManifest {
                window_id: Id128(99),
                frame_id,
                geometry_epoch: 1,
                source_submitted_ns: 100 + frame_id,
                received_ns: 110,
            },
            color: Bytes::from_static(b"color"),
            alpha: Some(Bytes::from_static(b"alpha")),
        }
    }
    fn codec(frame_id: u64, keyframe: bool) -> CodecFrameAdmission {
        CodecFrameAdmission {
            frame_id,
            config_generation: 1,
            paired_keyframe: keyframe,
        }
    }
    #[test]
    fn latest_feedback_frame_keeps_original_timestamp_and_replay_checks() {
        let mut gate = receiver();
        assert_eq!(gate.stage_with_expiry(layout(1), 151, true), Ok(false));
        assert_eq!(
            gate.admit(media(1), codec(1, true), 151).unwrap().layout,
            layout(1)
        );
        assert_eq!(
            gate.stage_with_expiry(layout(1), 152, true),
            Err(AtlasAdmissionError::Replay)
        );
        let mut conflict = layout(2);
        conflict.tiles[0].x = 16;
        assert_eq!(
            gate.stage_with_expiry(conflict, 152, true),
            Err(AtlasAdmissionError::LayoutConflict)
        );
        let mut source_replay = layout(2);
        source_replay.tiles[0].source_frame_id = 1;
        assert_eq!(
            gate.stage_with_expiry(source_replay, 152, true),
            Err(AtlasAdmissionError::SourceReplay)
        );
        assert_eq!(gate.stage_with_expiry(layout(2), 151, true), Ok(false));
        assert!(gate.admit(media(2), codec(2, true), 151).is_ok());
        // V2 continues to fail closed, without consuming the rejected manifest.
        let mut legacy = receiver();
        assert_eq!(
            legacy.stage(layout(1), 151),
            Err(AtlasAdmissionError::Expired)
        );
        assert!(legacy.stage(layout(1), 110).is_ok());
    }

    #[test]
    fn exact_pair_required_and_delivery_consumes_slot() {
        let mut gate = receiver();
        assert!(matches!(
            gate.admit(media(1), codec(1, true), 110),
            Err(AtlasAdmissionError::MissingManifest)
        ));
        gate.stage(layout(1), 110).unwrap();
        assert!(matches!(
            gate.admit(media(2), codec(2, true), 110),
            Err(AtlasAdmissionError::MediaMismatch)
        ));
        assert!(matches!(
            gate.admit(media(1), codec(1, false), 110),
            Err(AtlasAdmissionError::KeyframeRequired)
        ));
        assert_eq!(
            gate.admit(media(1), codec(1, true), 110).unwrap().layout,
            layout(1)
        );
        assert!(matches!(
            gate.admit(media(1), codec(1, true), 110),
            Err(AtlasAdmissionError::MissingManifest)
        ));
        gate.stage(layout(2), 110).unwrap();
        assert!(gate.admit(media(2), codec(2, false), 110).is_ok());
    }
    #[test]
    fn replacement_never_pairs_old_media_or_renews_time() {
        let mut gate = receiver();
        gate.stage(layout(1), 110).unwrap();
        gate.stage(layout(2), 110).unwrap();
        assert!(gate.stage(layout(1), 110).is_err());
        assert!(gate.admit(media(1), codec(1, true), 110).is_err());
        assert!(matches!(
            gate.admit(media(2), codec(2, true), 152),
            Err(AtlasAdmissionError::Expired)
        ));
    }
    #[test]
    fn layout_and_source_changes_need_new_generation() {
        let mut gate = receiver();
        gate.stage(layout(1), 110).unwrap();
        let mut changed = layout(2);
        changed.tiles[0].x = 16;
        assert_eq!(
            gate.stage(changed.clone(), 110),
            Err(AtlasAdmissionError::LayoutConflict)
        );
        changed.layout_revision = 2;
        assert_eq!(
            gate.stage(changed.clone(), 110),
            Err(AtlasAdmissionError::LayoutConflict)
        );
        changed.tiles[0].placement_generation = 2;
        gate.stage(changed, 110).unwrap();
        let mut replay = layout(3);
        replay.tiles[0].source_frame_id = 1;
        replay.layout_revision = 3;
        replay.tiles[0].placement_generation = 3;
        assert_eq!(
            gate.stage(replay, 110),
            Err(AtlasAdmissionError::SourceReplay)
        );
    }
    #[test]
    fn all_tiles_have_clock_bounds_and_alpha_is_required() {
        let mut gate = receiver();
        let mut future = layout(1);
        future.tiles.push(AtlasTile {
            window_id: Id128(2),
            x: 16,
            source_submitted_ns: 200,
            ..future.tiles[0].clone()
        });
        assert_eq!(
            gate.stage(future, 110),
            Err(AtlasAdmissionError::FutureTimestamp)
        );
        gate.stage(layout(1), 110).unwrap();
        let mut opaque = media(1);
        opaque.alpha = None;
        assert!(matches!(
            gate.admit(opaque, codec(1, true), 110),
            Err(AtlasAdmissionError::MissingAlpha)
        ));
        let mut oversized = media(1);
        oversized.color = Bytes::from(vec![0; 17]);
        assert!(matches!(
            gate.admit(oversized, codec(1, true), 110),
            Err(AtlasAdmissionError::ByteLimit)
        ));
    }

    #[test]
    fn layout_transition_and_resurrection_are_fenced() {
        let mut gate = receiver();
        gate.stage(layout(1), 110).unwrap();
        gate.admit(media(1), codec(1, true), 110).unwrap();
        let mut cleared = layout(2);
        cleared.tiles.clear();
        cleared.layout_revision = 2;
        gate.stage(cleared, 110).unwrap();
        assert!(matches!(
            gate.admit(media(2), codec(2, false), 110),
            Err(AtlasAdmissionError::KeyframeRequired)
        ));
        gate.admit(media(2), codec(2, true), 110).unwrap();
        let mut revived = layout(3);
        revived.layout_revision = 3;
        assert_eq!(
            gate.stage(revived.clone(), 110),
            Err(AtlasAdmissionError::LayoutConflict)
        );
        revived.tiles[0].placement_generation = 3;
        gate.stage(revived, 110).unwrap();
        assert!(matches!(
            gate.admit(media(3), codec(3, false), 110),
            Err(AtlasAdmissionError::KeyframeRequired)
        ));
        gate.admit(media(3), codec(3, true), 110).unwrap();
    }

    #[test]
    fn mismatches_leave_valid_pending_frame_intact() {
        let mut gate = receiver();
        gate.stage(layout(1), 110).unwrap();
        let mut wrong = layout(2);
        wrong.stream_id = Id128(88);
        assert_eq!(
            gate.stage(wrong, 110),
            Err(AtlasAdmissionError::WrongStream)
        );
        for field in 0..4 {
            let mut wrong = media(1);
            match field {
                0 => wrong.manifest.window_id = Id128(88),
                1 => wrong.manifest.geometry_epoch = 2,
                2 => wrong.manifest.source_submitted_ns += 1,
                _ => wrong.manifest.frame_id += 1,
            }
            assert!(matches!(
                gate.admit(wrong, codec(1, true), 110),
                Err(AtlasAdmissionError::MediaMismatch)
            ));
        }
        let mut wrong = codec(1, true);
        wrong.config_generation = 2;
        assert!(matches!(
            gate.admit(media(1), wrong, 110),
            Err(AtlasAdmissionError::MediaMismatch)
        ));
        gate.admit(media(1), codec(1, true), 110).unwrap();
    }
}
