//! Source pixel residency policy. Native geometry/input remain independent.
use serde::{Deserialize, Serialize};
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AtlasOcclusionMode {
    Off,
    #[default]
    Opaque,
    /// Compose coincident transparent source layers once. Local interleaving
    /// and movement may show a previous composition until the next scene arrives.
    Prerender,
}
