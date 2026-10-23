//! Lock helpers that keep a session running after an unrelated panic.
//!
//! A panic while holding a `std::sync::Mutex` poisons it, and every later
//! `lock().unwrap()` would panic too, spreading one task's failure to the
//! whole process. The guarded state in this crate is either replaced
//! wholesale or validated by its owner, so continuing with the last written
//! value is the recovery path rather than another panic.

use std::sync::{Mutex, MutexGuard, PoisonError};

pub(crate) trait LockExt<T: ?Sized> {
    fn lock_or_recover(&self) -> MutexGuard<'_, T>;
}

impl<T: ?Sized> LockExt<T> for Mutex<T> {
    #[inline]
    fn lock_or_recover(&self) -> MutexGuard<'_, T> {
        self.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    use super::LockExt;
    use std::sync::{Arc, Mutex};

    #[test]
    fn poisoned_lock_keeps_last_value() {
        let shared = Arc::new(Mutex::new(1));
        let writer = shared.clone();
        let _ = std::thread::spawn(move || {
            let mut value = writer.lock().unwrap();
            *value = 2;
            panic!("poison the lock");
        })
        .join();
        assert!(shared.is_poisoned());
        assert_eq!(*shared.lock_or_recover(), 2);
    }
}
