use viewflow_protocol::Id128;

// FNV-1a 128 is used only for deterministic local identifiers, not security.
const OFFSET_BASIS: u128 = 0x6c62_272e_07bb_0142_62b8_2175_6295_c58d;
const PRIME: u128 = 0x0000_0000_0100_0000_0000_0000_0000_013b;

pub(crate) fn stable_id(namespace: &str, parts: &[&str]) -> Id128 {
    let mut hash = OFFSET_BASIS;
    hash_bytes(&mut hash, namespace.as_bytes());
    for part in parts {
        hash_bytes(&mut hash, &part.len().to_le_bytes());
        hash_bytes(&mut hash, part.as_bytes());
    }
    Id128(hash)
}

fn hash_bytes(hash: &mut u128, bytes: &[u8]) {
    for byte in bytes {
        *hash ^= u128::from(*byte);
        *hash = hash.wrapping_mul(PRIME);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifiers_are_stable_and_length_delimited() {
        assert_eq!(stable_id("window", &["abc"]), stable_id("window", &["abc"]));
        assert_ne!(
            stable_id("window", &["ab", "c"]),
            stable_id("window", &["a", "bc"])
        );
        assert_ne!(
            stable_id("window", &["abc"]),
            stable_id("display", &["abc"])
        );
    }
}
