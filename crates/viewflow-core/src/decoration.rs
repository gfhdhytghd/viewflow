use viewflow_protocol::{Point, Rect, Size};

/// Capture-local logical rectangles, distinct from global desktop placement.
/// Pixels include source decorations; content coordinates start at (0, 0).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaptureGeometry {
    content: Rect,
    full: Rect,
    pixels: Size,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CaptureGeometryError {
    InvalidRect,
    InvalidPixels,
    ContentOutsideFrame,
}

/// The part of one decorated window visible on a destination display.
/// Pixel coordinates stay continuous until the final renderer chooses a
/// sampling filter, so adjacent displays share an exact boundary.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaptureSlice {
    pub desktop_rect: Rect,
    pub source_pixels: Rect,
}

impl CaptureGeometry {
    /// # Errors
    /// Rejects nonfinite/empty geometry and content not enclosed by the frame.
    pub fn new(
        content: Rect,
        full: Rect,
        width: u32,
        height: u32,
    ) -> Result<Self, CaptureGeometryError> {
        for rect in [content, full] {
            if ![
                rect.origin.x,
                rect.origin.y,
                rect.size.width,
                rect.size.height,
                rect.origin.x + rect.size.width,
                rect.origin.y + rect.size.height,
            ]
            .iter()
            .all(|v| v.is_finite())
                || rect.size.width <= 0.0
                || rect.size.height <= 0.0
            {
                return Err(CaptureGeometryError::InvalidRect);
            }
        }
        if width == 0 || height == 0 {
            return Err(CaptureGeometryError::InvalidPixels);
        }
        if content.origin.x < full.origin.x
            || content.origin.y < full.origin.y
            || content.origin.x + content.size.width > full.origin.x + full.size.width
            || content.origin.y + content.size.height > full.origin.y + full.size.height
        {
            return Err(CaptureGeometryError::ContentOutsideFrame);
        }
        Ok(Self {
            content,
            full,
            pixels: Size {
                width: f64::from(width),
                height: f64::from(height),
            },
        })
    }

    /// Map a main-surface-relative logical point to continuous artifact pixels.
    /// No rounding: callers choose rasterization policy at the final boundary.
    #[must_use]
    pub fn content_to_pixel(self, point: Point) -> Option<Point> {
        if !inside(
            point,
            Rect {
                origin: Point::default(),
                size: self.content.size,
            },
        ) {
            return None;
        }
        Some(Point {
            x: ((point.x + self.content.origin.x - self.full.origin.x) / self.full.size.width)
                * self.pixels.width,
            y: ((point.y + self.content.origin.y - self.full.origin.y) / self.full.size.height)
                * self.pixels.height,
        })
    }

    /// Reverse input mapping. Decoration pixels return None instead of being
    /// injected into content; decoration hit testing needs its own route.
    #[must_use]
    pub fn pixel_to_content(self, point: Point) -> Option<Point> {
        if !inside(
            point,
            Rect {
                origin: Point::default(),
                size: self.pixels,
            },
        ) {
            return None;
        }
        let content = Point {
            x: (point.x / self.pixels.width) * self.full.size.width + self.full.origin.x
                - self.content.origin.x,
            y: (point.y / self.pixels.height) * self.full.size.height + self.full.origin.y
                - self.content.origin.y,
        };
        inside(
            content,
            Rect {
                origin: Point::default(),
                size: self.content.size,
            },
        )
        .then_some(content)
    }

    /// Reverse a pointer inside the actually rendered destination pixel area.
    /// The slice may show only part of the decorated capture, at a different
    /// DPI. `point` must already exclude destination letterboxing. This maps
    /// geometry only: callers must separately validate window/epoch/lease.
    /// Source decorations and points outside the half-open viewport return None.
    #[must_use]
    pub fn slice_pixel_to_content(
        self,
        slice: CaptureSlice,
        presented_pixels: Size,
        point: Point,
    ) -> Option<Point> {
        let crop = slice.source_pixels;
        if ![
            presented_pixels.width,
            presented_pixels.height,
            crop.origin.x,
            crop.origin.y,
            crop.size.width,
            crop.size.height,
            crop.origin.x + crop.size.width,
            crop.origin.y + crop.size.height,
        ]
        .iter()
        .all(|value| value.is_finite())
            || presented_pixels.width <= 0.0
            || presented_pixels.height <= 0.0
            || crop.origin.x < 0.0
            || crop.origin.y < 0.0
            || crop.size.width <= 0.0
            || crop.size.height <= 0.0
            || crop.origin.x + crop.size.width > self.pixels.width
            || crop.origin.y + crop.size.height > self.pixels.height
            || !inside(
                point,
                Rect {
                    origin: Point::default(),
                    size: presented_pixels,
                },
            )
        {
            return None;
        }
        self.pixel_to_content(Point {
            x: crop.origin.x + (point.x / presented_pixels.width) * crop.size.width,
            y: crop.origin.y + (point.y / presented_pixels.height) * crop.size.height,
        })
    }

    /// Position the decorated frame when the main-surface global origin moves.
    #[must_use]
    pub fn placed_frame(self, content_origin: Point) -> Option<Rect> {
        let origin = Point {
            x: content_origin.x + self.full.origin.x - self.content.origin.x,
            y: content_origin.y + self.full.origin.y - self.content.origin.y,
        };
        [
            origin.x,
            origin.y,
            origin.x + self.full.size.width,
            origin.y + self.full.size.height,
        ]
        .iter()
        .all(|v| v.is_finite())
        .then_some(Rect {
            origin,
            size: self.full.size,
        })
    }

    /// Clip the decorated frame against a display in shared desktop logical
    /// coordinates, preserving border/shadow pixels on either side of a seam.
    #[must_use]
    pub fn slice_for_display(self, content_origin: Point, display: Rect) -> Option<CaptureSlice> {
        if ![
            display.origin.x,
            display.origin.y,
            display.size.width,
            display.size.height,
            display.origin.x + display.size.width,
            display.origin.y + display.size.height,
        ]
        .iter()
        .all(|v| v.is_finite())
            || display.size.width <= 0.0
            || display.size.height <= 0.0
        {
            return None;
        }
        let frame = self.placed_frame(content_origin)?;
        let desktop_rect = frame.intersection(display)?;
        // Normalize bounded logical distances first; precomputing pixels /
        // tiny logical sizes can overflow even when the resulting crop fits.
        Some(CaptureSlice {
            desktop_rect,
            source_pixels: Rect {
                origin: Point {
                    x: ((desktop_rect.origin.x - frame.origin.x) / self.full.size.width)
                        * self.pixels.width,
                    y: ((desktop_rect.origin.y - frame.origin.y) / self.full.size.height)
                        * self.pixels.height,
                },
                size: Size {
                    width: (desktop_rect.size.width / self.full.size.width) * self.pixels.width,
                    height: (desktop_rect.size.height / self.full.size.height) * self.pixels.height,
                },
            },
        })
    }
}

fn inside(point: Point, rect: Rect) -> bool {
    point.x.is_finite()
        && point.y.is_finite()
        && point.x >= rect.origin.x
        && point.y >= rect.origin.y
        && point.x < rect.origin.x + rect.size.width
        && point.y < rect.origin.y + rect.size.height
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn clipped_high_dpi_proxy_input_maps_to_content_without_double_scaling() {
        let geometry = CaptureGeometry::new(
            rect(0.0, 0.0, 100.0, 60.0),
            rect(-10.0, -10.0, 120.0, 80.0),
            240,
            160,
        )
        .unwrap();
        // Right half of the source content plus right decoration, rendered at
        // destination scale 1.5 while capture scale is 2.
        let slice = geometry
            .slice_for_display(Point::default(), rect(50.0, -10.0, 60.0, 80.0))
            .unwrap();
        let viewport = Size {
            width: 90.0,
            height: 120.0,
        };
        assert_eq!(
            geometry.slice_pixel_to_content(slice, viewport, Point { x: 0.0, y: 15.0 }),
            Some(Point { x: 50.0, y: 0.0 })
        );
        assert_eq!(
            geometry.slice_pixel_to_content(slice, viewport, Point { x: 30.0, y: 45.0 }),
            Some(Point { x: 70.0, y: 20.0 })
        );
        for point in [
            Point { x: 80.0, y: 45.0 },
            Point { x: 0.0, y: 0.0 },
            Point { x: 90.0, y: 45.0 },
            Point { x: -1.0, y: 45.0 },
            Point {
                x: f64::NAN,
                y: 45.0,
            },
        ] {
            assert_eq!(
                geometry.slice_pixel_to_content(slice, viewport, point),
                None
            );
        }
        let mut invalid = slice;
        invalid.source_pixels.size.width = 241.0;
        assert_eq!(
            geometry.slice_pixel_to_content(invalid, viewport, Point { x: 1.0, y: 20.0 }),
            None
        );
        assert_eq!(
            geometry.slice_pixel_to_content(slice, Size::default(), Point::default()),
            None
        );
    }
    #[test]
    fn large_finite_coordinates_round_trip_without_intermediate_overflow() {
        let bounds = rect(0.0, 0.0, 1e307, 1e307);
        let geometry = CaptureGeometry::new(bounds, bounds, 1000, 1000).unwrap();
        let logical = Point { x: 5e306, y: 5e306 };
        let pixels = geometry.content_to_pixel(logical).unwrap();
        assert_eq!(pixels, Point { x: 500.0, y: 500.0 });
        assert_eq!(geometry.pixel_to_content(pixels), Some(logical));
    }
    #[test]
    fn tiny_finite_logical_size_does_not_overflow_pixel_crop() {
        let bounds = rect(0.0, 0.0, 1e-308, 1e-308);
        let geometry = CaptureGeometry::new(bounds, bounds, 100, 100).unwrap();
        let slice = geometry
            .slice_for_display(Point::default(), bounds)
            .unwrap();
        assert_eq!(slice.source_pixels, rect(0.0, 0.0, 100.0, 100.0));
    }
    fn rect(x: f64, y: f64, width: f64, height: f64) -> Rect {
        Rect {
            origin: Point { x, y },
            size: Size { width, height },
        }
    }
    #[test]
    fn split_window_preserves_exact_fractional_pixel_seam_and_decorations() {
        let geometry = CaptureGeometry::new(
            rect(0.0, 0.0, 100.0, 50.0),
            rect(-7.0, -3.0, 114.0, 60.0),
            171,
            90,
        )
        .unwrap();
        let origin = Point {
            x: 1950.25,
            y: 10.0,
        };
        let left = geometry
            .slice_for_display(origin, rect(0.0, 0.0, 2000.0, 1000.0))
            .unwrap();
        let right = geometry
            .slice_for_display(origin, rect(2000.0, 0.0, 2000.0, 1000.0))
            .unwrap();
        assert_eq!(left.source_pixels.origin.x, 0.0);
        assert_eq!(left.source_pixels.size.width, 85.125);
        assert_eq!(right.source_pixels.origin.x, left.source_pixels.size.width);
        assert_eq!(
            left.source_pixels.size.width + right.source_pixels.size.width,
            171.0
        );
        assert_eq!(left.source_pixels.size.height, 90.0);
        assert!(
            geometry
                .slice_for_display(origin, rect(-1000.0, 0.0, 100.0, 100.0))
                .is_none()
        );
        assert!(
            geometry
                .slice_for_display(origin, rect(f64::NAN, 0.0, 100.0, 100.0))
                .is_none()
        );
    }
    #[test]
    fn live_hyprcapture_geometry_preserves_decoration_offset() {
        let geometry = CaptureGeometry::new(
            rect(0.0, 0.0, 268.0, 117.0),
            rect(-7.0, -7.0, 282.0, 131.0),
            564,
            262,
        )
        .unwrap();
        assert_eq!(
            geometry.content_to_pixel(Point::default()),
            Some(Point { x: 14.0, y: 14.0 })
        );
        assert_eq!(
            geometry.pixel_to_content(Point { x: 14.0, y: 14.0 }),
            Some(Point::default())
        );
        assert_eq!(geometry.pixel_to_content(Point { x: 1.0, y: 1.0 }), None);
        assert_eq!(
            geometry.placed_frame(Point { x: 1920.0, y: 40.0 }).unwrap(),
            rect(1913.0, 33.0, 282.0, 131.0)
        );
    }
    #[test]
    fn asymmetric_fractional_geometry_roundtrips() {
        let geometry = CaptureGeometry::new(
            rect(10.0, 20.0, 100.0, 50.0),
            rect(7.0, 11.0, 110.0, 70.0),
            165,
            105,
        )
        .unwrap();
        let point = Point { x: 25.5, y: 11.5 };
        assert_eq!(
            geometry.pixel_to_content(geometry.content_to_pixel(point).unwrap()),
            Some(point)
        );
        assert_eq!(geometry.content_to_pixel(Point { x: 100.0, y: 0.0 }), None);
        assert_eq!(
            geometry.pixel_to_content(Point {
                x: f64::NAN,
                y: 0.0
            }),
            None
        );
    }
    #[test]
    fn malformed_geometry_fails_closed() {
        let full = rect(0.0, 0.0, 10.0, 10.0);
        assert_eq!(
            CaptureGeometry::new(full, full, 0, 1),
            Err(CaptureGeometryError::InvalidPixels)
        );
        assert_eq!(
            CaptureGeometry::new(rect(-1.0, 0.0, 10.0, 10.0), full, 10, 10),
            Err(CaptureGeometryError::ContentOutsideFrame)
        );
        assert_eq!(
            CaptureGeometry::new(full, rect(f64::NAN, 0.0, 10.0, 10.0), 10, 10),
            Err(CaptureGeometryError::InvalidRect)
        );
    }
}
