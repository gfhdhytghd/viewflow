//! Platform-independent Viewflow state machines.

mod atlas;
mod audio;
mod coordinator;
mod decoration;
mod frame_queue;
mod hid;
mod topology;
mod transfer;
mod visibility;
mod window;
mod window_input;
mod window_keyboard;
pub use window_keyboard::WindowKeyboardGrant;

pub use atlas::{AtlasConfig, AtlasError, AtlasPlacement, AtlasRect, AtlasSnapshot, StableAtlas};
pub use audio::{
    ApplicationAudioLocations, AudioApplicationId, AudioCaptureScope, AudioForwardingDecision,
    AudioPlaybackMode, AudioRouteError, AudioRouter, ClearedAudioRoute, VersionedAudioRoute,
};
pub use coordinator::{Coordinator, CoordinatorError, CoordinatorOutcome};
pub use decoration::{CaptureGeometry, CaptureGeometryError, CaptureSlice};
pub use frame_queue::{FrameAdmission, FrameQueue, FrameQueueConfig, FrameRejectReason};
pub use hid::{ActiveHidRoute, HidLeaseError, HidLeaseManager};
pub use topology::{DisplaySlice, TopologyError, TopologyMap};
pub use transfer::{
    ClipboardTransfer, ClipboardTransferState, ClipboardTransfers, DragTransfer, DragTransferState,
    DragTransfers, TransferError,
};
pub use visibility::{Tile, VisibilityMap, visible_tiles};
pub use window::{MigrationState, WindowError, WindowSession};
pub use window_input::{PresentedInputGeometry, PresentedInputIdentity, WindowPointerGrant};
