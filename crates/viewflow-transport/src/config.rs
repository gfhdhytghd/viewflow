//! Local sender congestion policy. No protocol or idle-timeout changes.
use quinn::{
    TransportConfig,
    congestion::{BbrConfig, CubicConfig},
};
use std::sync::Arc;

/// Congestion control is independently selected by each sender.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum MediaCongestionController {
    Cubic,
    /// Quinn 0.11.19 marks this implementation experimental.
    Bbr,
    /// Experimental loss-tolerant Cubic with RTT/ECN congestion signals.
    #[default]
    DelayCubic,
}

/// Build a transport without changing Quinn's buffer or timeout defaults.
#[must_use]
pub fn media_transport_config_with(controller: MediaCongestionController) -> TransportConfig {
    let mut transport = TransportConfig::default();
    match controller {
        MediaCongestionController::Cubic => {
            transport.congestion_controller_factory(Arc::new(CubicConfig::default()))
        }
        MediaCongestionController::Bbr => {
            transport.congestion_controller_factory(Arc::new(BbrConfig::default()))
        }
        MediaCongestionController::DelayCubic => {
            transport.congestion_controller_factory(Arc::new(crate::delay_cubic::DelayCubicConfig))
        }
    };
    transport
}

/// Read when constructing a transport, never on the media hot path.
/// `VIEWFLOW_CONGESTION_CONTROL=cubic|bbr|delay_cubic` permits reproducible comparisons.
/// Invalid overrides retain the measured default and report the mistake.
#[must_use]
pub fn media_transport_config() -> TransportConfig {
    let controller = match std::env::var("VIEWFLOW_CONGESTION_CONTROL") {
        Ok(value) if value == "cubic" => MediaCongestionController::Cubic,
        Ok(value) if value == "delay_cubic" => MediaCongestionController::DelayCubic,
        Ok(value) if value == "bbr" => MediaCongestionController::Bbr,
        Ok(value) => {
            eprintln!("unknown VIEWFLOW_CONGESTION_CONTROL={value:?}; using default");
            MediaCongestionController::default()
        }
        Err(_) => MediaCongestionController::default(),
    };
    media_transport_config_with(controller)
}
