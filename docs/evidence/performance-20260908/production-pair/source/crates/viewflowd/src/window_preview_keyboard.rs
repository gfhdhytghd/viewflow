//! Separate keyboard authority and exact ACK handling on the mixed native FIFO.
use super::{
    ClockSnapshot, PreviewPointerEventReceiver, WindowPreviewInput,
    conservative_authorization_deadline,
};
use anyhow::{Context, Result, ensure};
use viewflow_core::PresentedInputIdentity;
use viewflow_protocol::{
    WindowKeyboardAck, WindowKeyboardAuthorization, WindowKeyboardMode, WindowKeyboardResult,
};

impl WindowPreviewInput {
    pub(crate) fn keyboard_presented(&self, identity: PresentedInputIdentity) -> bool {
        self.authorization.is_some_and(|pointer| {
            self.keyboard_history.iter().any(|auth| {
                auth.lease_generation == pointer.lease_generation
                    && auth.target_window == identity.window
                    && auth.geometry_epoch == identity.geometry_epoch
                    && auth.presented_frame == identity.frame
            })
        })
    }
    pub(super) fn bind_keyboard(
        &mut self,
        event: viewflow_protocol::WindowPointerMotion,
        key: Option<viewflow_protocol::KeyboardHidUsage>,
        snapshot: Option<ClockSnapshot>,
        now: u64,
    ) -> Result<u64> {
        let Some(key) = key else {
            return Ok(u64::MAX);
        };
        let deadline = self.keyboard_deadline(
            PresentedInputIdentity {
                window: event.target_window,
                geometry_epoch: event.geometry_epoch,
                frame: event.presented_frame,
            },
            event.lease_generation,
            snapshot,
            now,
        )?;
        self.pending_key = Some(viewflow_protocol::WindowKeyboardEvent {
            lease_generation: event.lease_generation,
            target_device: event.target_device,
            target_window: event.target_window,
            geometry_epoch: event.geometry_epoch,
            presented_frame: event.presented_frame,
            sequence: event.sequence,
            sender_not_after_ns: event.sender_not_after_ns,
            key,
        });
        Ok(deadline)
    }
    /// Local policy enabling the shared motion/button/wheel/key stream. Source
    /// keyboard authority remains independently required for every key event.
    /// # Errors
    /// Rejects replacing an active or already configured event stream.
    pub fn with_direct_keyboard(self, events: PreviewPointerEventReceiver) -> Result<Self> {
        let mut result = self.with_buttons_and_wheel(events)?;
        result.allow_keyboard = true;
        Ok(result)
    }

    pub(crate) fn authorize_keyboard(&mut self, auth: WindowKeyboardAuthorization) -> Result<()> {
        ensure!(
            self.allow_keyboard,
            "keyboard forwarding is not locally enabled"
        );
        ensure!(
            auth.owner_device == self.owner
                && self.accepts_selected_geometry(auth.geometry_epoch)
                && self
                    .geometry_generation_floor
                    .is_none_or(|floor| auth.lease_generation > floor)
                && auth.target_device == self.source
                && auth.target_window == self.window
                && auth.lease_generation != 0
                && auth.geometry_epoch != 0
                && auth.presented_frame != 0
                && auth.source_not_after_ns != 0
                && auth.mode == WindowKeyboardMode::DirectApplication,
            "keyboard authority differs from selected local route"
        );
        if let Some(previous) = self.keyboard_authorization {
            let same = auth.lease_generation == previous.lease_generation
                && auth.source_not_after_ns == previous.source_not_after_ns;
            let renewed = auth.lease_generation > previous.lease_generation
                && auth.source_not_after_ns > previous.source_not_after_ns
                && auth.presented_frame > previous.presented_frame;
            ensure!(
                (same || renewed)
                    && auth.geometry_epoch == previous.geometry_epoch
                    && auth.presented_frame >= previous.presented_frame,
                "keyboard authority regressed or changed geometry"
            );
            ensure!(
                !renewed || self.deferred_receipt.is_none(),
                "keyboard renewal changed a deferred event"
            );
            if renewed {
                self.keyboard_history.clear();
            }
        }
        if self.keyboard_history.back() != Some(&auth) {
            self.keyboard_history.push_back(auth);
            if self.keyboard_history.len() > 32 {
                self.keyboard_history.pop_front();
            }
        }
        self.keyboard_authorization = Some(auth);
        Ok(())
    }

    pub(super) fn keyboard_deadline(
        &self,
        identity: PresentedInputIdentity,
        generation: u64,
        snapshot: Option<ClockSnapshot>,
        now: u64,
    ) -> Result<u64> {
        let auth = self
            .keyboard_history
            .iter()
            .rev()
            .find(|auth| {
                auth.lease_generation == generation
                    && auth.target_window == identity.window
                    && auth.geometry_epoch == identity.geometry_epoch
                    && auth.presented_frame == identity.frame
            })
            .context("key lacks exact source keyboard presentation authority")?;
        conservative_authorization_deadline(auth.source_not_after_ns, snapshot, now)
            .map_err(|error| anyhow::anyhow!("keyboard source clock or lease invalid: {error:?}"))
    }

    pub(crate) fn acknowledge_keyboard(&mut self, ack: WindowKeyboardAck) -> Result<()> {
        let event = self.pending_key.context("unsolicited keyboard ACK")?;
        let (_, deadline) = self.pending.context("keyboard ACK without pending FIFO")?;
        ensure!(
            ack.event == event && ack.result == WindowKeyboardResult::KeySent,
            "keyboard ACK is not the exact native confirmation"
        );
        ensure!(self.now_ns()? < deadline, "keyboard ACK expired");
        self.pending_key = None;
        self.set_pending(None);
        self.pending_timing = None;
        Ok(())
    }
}
