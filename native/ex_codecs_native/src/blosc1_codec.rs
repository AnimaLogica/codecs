//! Blosc1 chunk encoder (c-blosc 1.x wire format, pure Rust).
//!
//! Zarr v2 and v3 `blosc` codecs, and numcodecs, use the Blosc1 chunk format
//! (header version 2). The Blosc2 writer in `blosc2_codec` emits a newer header
//! that c-blosc 1.x rejects, so this module writes Blosc1 chunks directly.
//! Decoding goes through `blosc2_pure_rs`, which reads both formats.
//!
//! Chunk layout:
//!
//! ```text
//! header (16 bytes)
//!   0  version format (2)
//!   1  compressor format version (1)
//!   2  flags: 0x01 byte shuffle, 0x02 memcpyed, 0x04 bit shuffle,
//!            0x10 blocks not split, bits 5-7 compressor format
//!   3  typesize
//!   4  nbytes    (u32 LE, uncompressed size)
//!   8  blocksize (u32 LE)
//!   12 cbytes    (u32 LE, total chunk size)
//! bstarts: one u32 LE offset per block (absent when memcpyed)
//! blocks:  per block, u32 LE stream size followed by the stream; a stream
//!          whose size equals the block size is stored uncompressed
//! ```
//!
//! Blocks are never split into per-byte streams (flag 0x10), which c-blosc
//! 1.14 and later honour. Bitshuffle is applied only to blocks whose element
//! count is a multiple of 8, as c-blosc 1.x does; other blocks are stored
//! without the filter.

use std::io::Write;

use rustler::{Binary, Env, Term};

use crate::atoms;
use crate::util::{err, ok_binary};

use blosc2_pure_rs::codecs::blosclz;
use blosc2_pure_rs::filters::{bitshuffle, shuffle};

const HEADER_LEN: usize = 16;
const VERSION_FORMAT: u8 = 2;
const COMPRESSOR_VERSION_FORMAT: u8 = 1;
const MIN_BUFFERSIZE: usize = 128;

const FLAG_SHUFFLE: u8 = 0x01;
const FLAG_MEMCPYED: u8 = 0x02;
const FLAG_BITSHUFFLE: u8 = 0x04;
const FLAG_DONT_SPLIT: u8 = 0x10;

#[derive(Clone, Copy, PartialEq)]
enum Compressor {
    BloscLz,
    Lz4,
    Zlib,
    Zstd,
}

impl Compressor {
    // cname ints shared with the Blosc2 NIF: 0 blosclz, 1 lz4, 2 lz4hc, 4 zlib, 5 zstd.
    fn from_cname(cname: i64) -> Option<Self> {
        match cname {
            0 => Some(Self::BloscLz),
            // LZ4HC writes the same LZ4 block format; lz4_flex has no HC mode.
            1 | 2 => Some(Self::Lz4),
            4 => Some(Self::Zlib),
            5 => Some(Self::Zstd),
            _ => None,
        }
    }

    // Compressor format code stored in flag bits 5-7.
    fn format(self) -> u8 {
        match self {
            Self::BloscLz => 0,
            Self::Lz4 => 1,
            Self::Zlib => 3,
            Self::Zstd => 4,
        }
    }

    // Blocks get larger for the slower, higher-ratio codecs, as in c-blosc.
    fn block_scale(self) -> usize {
        match self {
            Self::Zlib | Self::Zstd => 2,
            _ => 1,
        }
    }

    /// Compresses one stream. `None` means "store uncompressed".
    fn compress(self, clevel: u8, input: &[u8]) -> Option<Vec<u8>> {
        let out = match self {
            Self::BloscLz => {
                if input.len() < 16 {
                    return None;
                }
                let mut buf = vec![0u8; input.len().max(66)];
                let n = blosclz::compress(clevel as i32, input, &mut buf);
                if n <= 0 {
                    return None;
                }
                buf.truncate(n as usize);
                buf
            }
            Self::Lz4 => lz4_flex::block::compress(input),
            Self::Zlib => {
                let mut enc = flate2::write::ZlibEncoder::new(
                    Vec::with_capacity(input.len() / 2),
                    flate2::Compression::new(clevel as u32),
                );
                enc.write_all(input).ok()?;
                enc.finish().ok()?
            }
            Self::Zstd => {
                // c-blosc 1.x maps clevel 1..9 onto zstd levels the same way.
                let level = match clevel {
                    9 => 22,
                    8 => 20,
                    l => (l as i32) * 2 - 1,
                };
                structured_zstd::encoding::compress_to_vec(
                    input,
                    structured_zstd::encoding::CompressionLevel::from_level(level.clamp(1, 22)),
                )
            }
        };
        (out.len() < input.len()).then_some(out)
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Shuffle {
    None,
    Byte,
    Bit,
}

impl Shuffle {
    fn from_int(shuffle: i64) -> Option<Self> {
        match shuffle {
            0 => Some(Self::None),
            1 => Some(Self::Byte),
            2 => Some(Self::Bit),
            _ => None,
        }
    }
}

fn blocksize_for(nbytes: usize, clevel: u8, typesize: usize, compressor: Compressor) -> usize {
    let base = match clevel {
        0..=3 => 64 * 1024,
        4..=6 => 128 * 1024,
        _ => 256 * 1024,
    } * compressor.block_scale();

    if nbytes <= base {
        return nbytes;
    }
    // Whole groups of 8 elements, so bitshuffle covers every full block.
    let unit = typesize * 8;
    (base / unit).max(1) * unit
}

/// Applies the shuffle filter to one block. Blocks the filter cannot cover
/// (bitshuffle needs whole groups of 8 elements) are returned unchanged.
fn filter_block(block: &[u8], shuffle_mode: Shuffle, typesize: usize) -> Vec<u8> {
    let mut out = vec![0u8; block.len()];
    match shuffle_mode {
        Shuffle::Byte if typesize > 1 => shuffle(typesize, block, &mut out),
        Shuffle::Bit if (block.len() / typesize).is_multiple_of(8) => {
            bitshuffle(typesize, block, &mut out);
        }
        _ => out.copy_from_slice(block),
    }
    out
}

fn header(flags: u8, typesize: usize, nbytes: usize, blocksize: usize, cbytes: usize) -> [u8; 16] {
    let mut h = [0u8; HEADER_LEN];
    h[0] = VERSION_FORMAT;
    h[1] = COMPRESSOR_VERSION_FORMAT;
    h[2] = flags;
    h[3] = typesize as u8;
    h[4..8].copy_from_slice(&(nbytes as u32).to_le_bytes());
    h[8..12].copy_from_slice(&(blocksize as u32).to_le_bytes());
    h[12..16].copy_from_slice(&(cbytes as u32).to_le_bytes());
    h
}

// Flags describing the requested filter, set on every chunk like c-blosc does
// (including memcpyed ones and typesize 1, where decoders treat them as no-ops).
fn shuffle_flags(shuffle_mode: Shuffle) -> u8 {
    match shuffle_mode {
        Shuffle::Byte => FLAG_SHUFFLE,
        Shuffle::Bit => FLAG_BITSHUFFLE,
        Shuffle::None => 0,
    }
}

// Uncompressed chunk. c-blosc writes blocksize 1 for empty input.
fn memcpyed_chunk(
    src: &[u8],
    typesize: usize,
    compressor: Compressor,
    filter_flags: u8,
) -> Vec<u8> {
    let flags = FLAG_MEMCPYED | FLAG_DONT_SPLIT | filter_flags | (compressor.format() << 5);
    let blocksize = src.len().max(1);
    let mut chunk = Vec::with_capacity(HEADER_LEN + src.len());
    chunk.extend_from_slice(&header(
        flags,
        typesize,
        src.len(),
        blocksize,
        HEADER_LEN + src.len(),
    ));
    chunk.extend_from_slice(src);
    chunk
}

/// Encodes `src` as one Blosc1 chunk.
fn encode(
    src: &[u8],
    compressor: Compressor,
    clevel: u8,
    shuffle_mode: Shuffle,
    typesize: usize,
) -> Vec<u8> {
    let nbytes = src.len();
    let filter_flags = shuffle_flags(shuffle_mode);
    if clevel == 0 || nbytes < MIN_BUFFERSIZE {
        return memcpyed_chunk(src, typesize, compressor, filter_flags);
    }

    let blocksize = blocksize_for(nbytes, clevel, typesize, compressor);
    let nblocks = nbytes.div_ceil(blocksize);
    let data_start = HEADER_LEN + 4 * nblocks;

    let mut body: Vec<u8> = Vec::with_capacity(nbytes / 2);
    let mut bstarts: Vec<u32> = Vec::with_capacity(nblocks);

    for block in src.chunks(blocksize) {
        bstarts.push((data_start + body.len()) as u32);
        let filtered = filter_block(block, shuffle_mode, typesize);
        let stream = compressor.compress(clevel, &filtered);
        let payload = stream.as_deref().unwrap_or(&filtered);
        body.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        body.extend_from_slice(payload);

        // Give up early once the chunk cannot beat a plain copy.
        if data_start + body.len() >= HEADER_LEN + nbytes {
            return memcpyed_chunk(src, typesize, compressor, filter_flags);
        }
    }

    let flags = FLAG_DONT_SPLIT | filter_flags | (compressor.format() << 5);

    let cbytes = data_start + body.len();
    let mut chunk = Vec::with_capacity(cbytes);
    chunk.extend_from_slice(&header(flags, typesize, nbytes, blocksize, cbytes));
    for start in bstarts {
        chunk.extend_from_slice(&start.to_le_bytes());
    }
    chunk.extend_from_slice(&body);
    chunk
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn blosc1_compress<'a>(
    env: Env<'a>,
    data: Binary,
    cname: i64,
    clevel: i64,
    shuffle: i64,
    typesize: i64,
) -> Term<'a> {
    let (Some(compressor), Some(shuffle_mode)) =
        (Compressor::from_cname(cname), Shuffle::from_int(shuffle))
    else {
        return err(env, atoms::invalid_options());
    };
    if !(0..=9).contains(&clevel) || !(1..=255).contains(&typesize) {
        return err(env, atoms::invalid_options());
    }
    if data.len() > (i32::MAX as usize) - HEADER_LEN {
        return err(env, atoms::invalid_data());
    }

    let chunk = encode(
        data.as_slice(),
        compressor,
        clevel as u8,
        shuffle_mode,
        typesize as usize,
    );
    ok_binary(env, &chunk)
}

#[cfg(test)]
mod tests {
    use super::*;
    use blosc2_pure_rs::{blosc2_create_dctx, blosc2_decompress_ctx, blosc2_free_ctx, DParams};

    fn decode(chunk: &[u8]) -> Result<Vec<u8>, i32> {
        let nbytes = u32::from_le_bytes(chunk[4..8].try_into().unwrap()) as usize;
        let ctx = blosc2_create_dctx(DParams {
            nthreads: 1,
            ..Default::default()
        })
        .unwrap();
        let mut out = vec![0u8; nbytes.max(1)];
        let capacity = out.len() as i32;
        let n = blosc2_decompress_ctx(&ctx, chunk, chunk.len() as i32, &mut out, capacity);
        blosc2_free_ctx(ctx);
        if n < 0 {
            return Err(n);
        }
        out.truncate(n as usize);
        Ok(out)
    }

    fn sample(n: usize) -> Vec<u8> {
        (0..n as u64)
            .flat_map(|i| (i * 3 / 2).to_le_bytes())
            .collect()
    }

    #[test]
    fn round_trips_every_compressor_and_filter() {
        let compressors = [
            Compressor::BloscLz,
            Compressor::Lz4,
            Compressor::Zlib,
            Compressor::Zstd,
        ];
        let filters = [Shuffle::None, Shuffle::Byte, Shuffle::Bit];
        // sizes cover memcpyed, single block, multi block and partial blocks
        for &len in &[0usize, 7, 127, 128, 1000, 70_001, 600_003] {
            let src: Vec<u8> = sample(len.div_ceil(8)).into_iter().take(len).collect();
            for &c in &compressors {
                for &f in &filters {
                    for &ts in &[1usize, 4, 8] {
                        let chunk = encode(&src, c, 5, f, ts);
                        assert_eq!(chunk[0], VERSION_FORMAT);
                        assert_eq!(
                            decode(&chunk),
                            Ok(src.clone()),
                            "len={len} ts={ts} flags={:#x}",
                            chunk[2]
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn incompressible_data_is_memcpyed() {
        let mut x: u64 = 0x9E37_79B9_7F4A_7C15;
        let src: Vec<u8> = (0..4096)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                x as u8
            })
            .collect();
        let chunk = encode(&src, Compressor::Lz4, 5, Shuffle::None, 1);
        assert_eq!(chunk[2] & FLAG_MEMCPYED, FLAG_MEMCPYED);
        assert_eq!(chunk.len(), HEADER_LEN + src.len());
        assert_eq!(decode(&chunk), Ok(src));
    }
}
