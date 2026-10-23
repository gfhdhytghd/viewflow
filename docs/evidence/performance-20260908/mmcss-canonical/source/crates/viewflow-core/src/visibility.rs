use viewflow_protocol::Rect;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Tile {
    pub x: u32,
    pub y: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VisibilityMap {
    pub columns: u32,
    pub rows: u32,
    pub visible: Vec<bool>,
}

/// Returns tiles not fully covered by an opaque rectangle above the window.
/// Translucent coverage must not be passed to this function.
#[must_use]
pub fn visible_tiles(window: Rect, opaque_above: &[Rect], tile_size_dip: f64) -> VisibilityMap {
    fn tile_count(extent: f64, tile_size: f64) -> u32 {
        if !extent.is_finite() || !tile_size.is_finite() || extent <= 0.0 || tile_size <= 0.0 {
            return 0;
        }
        let count = (extent / tile_size).ceil().min(f64::from(u32::MAX));
        // The finite positive value is explicitly clamped to the u32 domain.
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let count = count as u32;
        count
    }

    let columns = tile_count(window.size.width, tile_size_dip);
    let rows = tile_count(window.size.height, tile_size_dip);
    let mut visible = Vec::with_capacity((columns * rows) as usize);
    for row in 0..rows {
        for column in 0..columns {
            let tile = Rect {
                origin: viewflow_protocol::Point {
                    x: window.origin.x + f64::from(column) * tile_size_dip,
                    y: window.origin.y + f64::from(row) * tile_size_dip,
                },
                size: viewflow_protocol::Size {
                    width: tile_size_dip.min(window.size.width - f64::from(column) * tile_size_dip),
                    height: tile_size_dip.min(window.size.height - f64::from(row) * tile_size_dip),
                },
            };
            let covered = opaque_above.iter().any(|opaque| {
                opaque
                    .intersection(tile)
                    .is_some_and(|intersection| intersection.area() >= tile.area())
            });
            visible.push(!covered);
        }
    }
    VisibilityMap {
        columns,
        rows,
        visible,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::{Point, Size};

    #[test]
    fn culls_only_fully_covered_tiles() {
        let window = Rect {
            origin: Point::default(),
            size: Size {
                width: 200.0,
                height: 100.0,
            },
        };
        let opaque = Rect {
            origin: Point::default(),
            size: Size {
                width: 100.0,
                height: 100.0,
            },
        };
        let map = visible_tiles(window, &[opaque], 100.0);
        assert_eq!(map.visible, vec![false, true]);
    }
}
