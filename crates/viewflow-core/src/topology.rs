use viewflow_protocol::{DeviceId, DeviceTopology, DisplayDescriptor, Rect, WindowDescriptor};

#[derive(Clone, Debug, PartialEq)]
pub struct DisplaySlice {
    pub display: DisplayDescriptor,
    pub visible_bounds_dip: Rect,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TopologyError {
    InvalidScale,
    InvalidRefreshRate,
    DuplicateDisplay,
}

#[derive(Clone, Debug)]
pub struct TopologyMap {
    topology: DeviceTopology,
}

impl TopologyMap {
    /// Builds a validated logical-display map.
    ///
    /// # Errors
    ///
    /// Returns an error when a display has an invalid scale or refresh rate, or
    /// when two displays use the same stable identifier.
    pub fn new(topology: DeviceTopology) -> Result<Self, TopologyError> {
        for (index, display) in topology.displays.iter().enumerate() {
            if !display.scale.is_finite() || display.scale <= 0.0 {
                return Err(TopologyError::InvalidScale);
            }
            if display.refresh_millihz == 0 {
                return Err(TopologyError::InvalidRefreshRate);
            }
            if topology.displays[..index]
                .iter()
                .any(|candidate| candidate.id == display.id)
            {
                return Err(TopologyError::DuplicateDisplay);
            }
        }
        Ok(Self { topology })
    }

    #[must_use]
    pub fn generation(&self) -> u64 {
        self.topology.generation
    }

    #[must_use]
    pub fn slices_for(&self, window: &WindowDescriptor) -> Vec<DisplaySlice> {
        self.topology
            .displays
            .iter()
            .filter_map(|display| {
                window
                    .bounds_dip
                    .intersection(display.bounds_dip)
                    .map(|visible_bounds_dip| DisplaySlice {
                        display: display.clone(),
                        visible_bounds_dip,
                    })
            })
            .collect()
    }

    #[must_use]
    pub fn render_scale_for(&self, window: &WindowDescriptor) -> Option<f64> {
        self.slices_for(window)
            .into_iter()
            .map(|slice| slice.display.scale)
            .reduce(f64::max)
    }

    #[must_use]
    pub fn devices_for(&self, window: &WindowDescriptor) -> Vec<DeviceId> {
        let mut devices = Vec::new();
        for slice in self.slices_for(window) {
            if !devices.contains(&slice.display.device_id) {
                devices.push(slice.display.device_id);
            }
        }
        devices
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::{Id128, Point, Size, WindowRole};

    fn rect(x: f64, width: f64) -> Rect {
        Rect {
            origin: Point { x, y: 0.0 },
            size: Size {
                width,
                height: 100.0,
            },
        }
    }

    #[test]
    fn slices_cross_device_window_and_uses_highest_scale() {
        let source = Id128(1);
        let remote = Id128(2);
        let topology = TopologyMap::new(DeviceTopology {
            generation: 4,
            displays: vec![
                DisplayDescriptor {
                    id: Id128(10),
                    device_id: source,
                    bounds_dip: rect(0.0, 100.0),
                    scale: 1.0,
                    refresh_millihz: 60_000,
                },
                DisplayDescriptor {
                    id: Id128(11),
                    device_id: remote,
                    bounds_dip: rect(100.0, 100.0),
                    scale: 2.0,
                    refresh_millihz: 60_000,
                },
            ],
        })
        .unwrap();
        let window = WindowDescriptor {
            id: Id128(20),
            family_id: Id128(21),
            source_device: source,
            role: WindowRole::Main,
            bounds_dip: rect(75.0, 50.0),
            min_size_dip: Size::default(),
            max_size_dip: None,
            has_alpha: true,
            blur_radius_dip: None,
        };

        let slices = topology.slices_for(&window);
        assert_eq!(slices.len(), 2);
        assert!((slices[0].visible_bounds_dip.area() - 2_500.0).abs() < f64::EPSILON);
        assert_eq!(topology.render_scale_for(&window), Some(2.0));
        assert_eq!(topology.devices_for(&window), vec![source, remote]);
    }
}
