#![no_main]
use libfuzzer_sys::fuzz_target;
use viewflowd::audio_wire::{decode, encode};

fuzz_target!(|data: &[u8]| {
    if let Ok((generation, sequence, pcm)) = decode(data) {
        assert_eq!(
            encode(generation, sequence, pcm).expect("packet re-encodes"),
            data
        );
    }
});
