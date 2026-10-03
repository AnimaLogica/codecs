//! C-Blosc2-compatible chunk compress/decompress (pure Rust).
//!
//! Uses [`blosc2_pure_rs`] for the official chunk wire format (header, blocks,
//! filters, codecs including BloscLZ and LZ4HC). No C-Blosc2 is linked.

use rustler::{Binary, Env, Term};

use crate::atoms;
use crate::util::{err, ok_binary};

use blosc2_pure_rs::{
    blosc2_compress_ctx, blosc2_create_cctx, blosc2_create_dctx, blosc2_decompress_ctx,
    blosc2_free_ctx, blosc2_get_version_string, CParams, DParams, BLOSC2_MAX_OVERHEAD,
    BLOSC_BITSHUFFLE, BLOSC_BLOSCLZ, BLOSC_LZ4, BLOSC_LZ4HC, BLOSC_NOSHUFFLE, BLOSC_SHUFFLE,
    BLOSC_ZLIB, BLOSC_ZSTD,
};

pub fn version() -> String {
    format!("c-blosc2-chunk/{}", blosc2_get_version_string())
}

fn filter_from_shuffle(shuffle: u8) -> u8 {
    match shuffle {
        0 => BLOSC_NOSHUFFLE,
        1 => BLOSC_SHUFFLE,
        2 => BLOSC_BITSHUFFLE,
        _ => BLOSC_NOSHUFFLE,
    }
}

fn compcode_from_cname(cname: u8) -> Option<u8> {
    match cname {
        0 => Some(BLOSC_BLOSCLZ),
        1 => Some(BLOSC_LZ4),
        2 => Some(BLOSC_LZ4HC),
        4 => Some(BLOSC_ZLIB),
        5 => Some(BLOSC_ZSTD),
        // 3 was historical snappy; not a standard C-Blosc2 compressor id path here
        _ => None,
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn blosc2_compress<'a>(
    env: Env<'a>,
    data: Binary,
    cname: i64,
    clevel: i64,
    shuffle: i64,
    typesize: usize,
) -> Term<'a> {
    let clevel = clevel.clamp(0, 9) as u8;
    let typesize = typesize.clamp(1, 255) as i32;
    let Some(compcode) = compcode_from_cname(cname as u8) else {
        return err(env, atoms::invalid_options());
    };
    let filter = filter_from_shuffle(shuffle.clamp(0, 2) as u8);

    let overhead = BLOSC2_MAX_OVERHEAD;
    let max_src = (i32::MAX as usize).saturating_sub(overhead);
    if data.len() > max_src {
        return err(env, atoms::invalid_data());
    }

    let cparams = CParams {
        compcode,
        clevel,
        typesize,
        nthreads: 1,
        filters: [0, 0, 0, 0, 0, filter],
        filters_meta: [0; 6],
        ..Default::default()
    };

    let ctx = match blosc2_create_cctx(cparams) {
        Ok(ctx) => ctx,
        Err(_) => return err(env, atoms::invalid_options()),
    };

    let src = data.as_slice();
    let Ok(srcsize) = i32::try_from(src.len()) else {
        blosc2_free_ctx(ctx);
        return err(env, atoms::invalid_data());
    };
    let Ok(mut destsize) = i32::try_from(src.len() + overhead) else {
        blosc2_free_ctx(ctx);
        return err(env, atoms::invalid_data());
    };
    if destsize < BLOSC2_MAX_OVERHEAD as i32 {
        destsize = BLOSC2_MAX_OVERHEAD as i32;
    }
    let mut dest = vec![0u8; destsize as usize];

    let n = blosc2_compress_ctx(&ctx, src, srcsize, &mut dest, destsize);
    blosc2_free_ctx(ctx);

    if n < 0 {
        return err(env, atoms::compression_failed());
    }
    if n == 0 {
        // Destination too small — retry with a larger buffer.
        let Some(destsize2_usize) = src.len().checked_mul(2).map(|n| n + overhead) else {
            return err(env, atoms::compression_failed());
        };
        let destsize2_usize = destsize2_usize.max(overhead);
        let Ok(destsize2) = i32::try_from(destsize2_usize) else {
            return err(env, atoms::compression_failed());
        };
        let mut dest2 = vec![0u8; destsize2 as usize];
        let cparams2 = CParams {
            compcode,
            clevel,
            typesize,
            nthreads: 1,
            filters: [0, 0, 0, 0, 0, filter],
            ..Default::default()
        };
        let Ok(ctx2) = blosc2_create_cctx(cparams2) else {
            return err(env, atoms::compression_failed());
        };
        let n2 = blosc2_compress_ctx(&ctx2, src, srcsize, &mut dest2, destsize2);
        blosc2_free_ctx(ctx2);
        if n2 <= 0 {
            return err(env, atoms::compression_failed());
        }
        dest2.truncate(n2 as usize);
        return ok_binary(env, &dest2);
    }

    dest.truncate(n as usize);
    ok_binary(env, &dest)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn blosc2_decompress<'a>(env: Env<'a>, data: Binary, max_output_size: u64) -> Term<'a> {
    if data.len() < 16 {
        return err(env, atoms::invalid_data());
    }

    // nbytes at offset 4 (little-endian int32) in the Blosc chunk header.
    let nbytes = u32::from_le_bytes([data[4], data[5], data[6], data[7]]) as usize;
    // Cap single-chunk decompress to 1 GiB, and to the caller-supplied limit.
    if nbytes > (1usize << 30) || !crate::util::output_within_limit(nbytes, max_output_size) {
        return err(env, atoms::output_limit_exceeded());
    }

    let dparams = DParams {
        nthreads: 1,
        ..Default::default()
    };
    let ctx = match blosc2_create_dctx(dparams) {
        Ok(ctx) => ctx,
        Err(_) => return err(env, atoms::decompression_failed()),
    };

    let src = data.as_slice();
    let srcsize = src.len() as i32;
    let mut dest = vec![0u8; nbytes.max(1)];
    let destsize = dest.len() as i32;

    let n = blosc2_decompress_ctx(&ctx, src, srcsize, &mut dest, destsize);
    blosc2_free_ctx(ctx);

    if n < 0 {
        return err(env, atoms::decompression_failed());
    }

    dest.truncate(n as usize);
    ok_binary(env, &dest)
}
