//! CRC32C (Castagnoli) checksum, as used by the Zarr v3 `crc32c` codec and the
//! `sharding_indexed` index.

use rustler::{Binary, Env, Term};

use crate::atoms;
use crate::util::{err, ok_binary};

pub fn version() -> String {
    "crc32c-0.6".to_string()
}

#[rustler::nif]
pub fn crc32c_checksum(data: Binary) -> u32 {
    crc32c::crc32c(data.as_slice())
}

/// Appends the little-endian CRC32C of `data`.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn crc32c_encode<'a>(env: Env<'a>, data: Binary) -> Term<'a> {
    let src = data.as_slice();
    let mut out = Vec::with_capacity(src.len() + 4);
    out.extend_from_slice(src);
    out.extend_from_slice(&crc32c::crc32c(src).to_le_bytes());
    ok_binary(env, &out)
}

/// Verifies and strips a trailing little-endian CRC32C.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn crc32c_decode<'a>(env: Env<'a>, data: Binary) -> Term<'a> {
    let src = data.as_slice();
    if src.len() < 4 {
        return err(env, atoms::truncated_input());
    }
    let (payload, stored) = src.split_at(src.len() - 4);
    let stored = u32::from_le_bytes([stored[0], stored[1], stored[2], stored[3]]);
    if crc32c::crc32c(payload) != stored {
        return err(env, atoms::checksum_mismatch());
    }
    ok_binary(env, payload)
}
