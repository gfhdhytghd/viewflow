//! Local resource failures retry without retiring the connection or other windows.
use std::time::Duration;

#[derive(Debug)]
pub struct RecoveryBackoff {
    next: Duration,
}
impl Default for RecoveryBackoff {
    fn default() -> Self {
        Self {
            next: Duration::from_secs(1),
        }
    }
}
impl RecoveryBackoff {
    pub fn reset(&mut self) {
        *self = Self::default();
    }
    pub fn delay(&mut self) -> Duration {
        let delay = self.next;
        self.next = (self.next * 2).min(Duration::from_secs(30));
        delay
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identical_failures_keep_retrying_with_capped_backoff() {
        let mut retry = RecoveryBackoff::default();
        let delays: Vec<_> = (0..500).map(|_| retry.delay().as_secs()).collect();
        assert_eq!(&delays[..6], &[1, 2, 4, 8, 16, 30]);
        assert!(delays[6..].iter().all(|&delay| delay == 30));
        retry.reset();
        assert_eq!(retry.delay(), Duration::from_secs(1));
    }
}
