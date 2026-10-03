//! Spatial binary hot paths: EXCP / GSPL / binary PLY unpack & pack.
//!
//! Wire formats match `docs/spatial_formats.md` and the pure-Elixir codecs.

use std::fs::File;
use std::io::Write;

use memmap2::Mmap;
use rustler::types::atom;
use rustler::{Binary, Encoder, Env, NifResult, Resource, ResourceArc, Term};

use crate::atoms;
use crate::util::{err, ok_binary};

const FLAG_COLOR: u16 = 0b001;
const FLAG_ALPHA: u16 = 0b010;
const FLAG_NORMAL: u16 = 0b100;

const PLY_CHAR: u8 = 1;
const PLY_UCHAR: u8 = 2;
const PLY_SHORT: u8 = 3;
const PLY_USHORT: u8 = 4;
const PLY_INT: u8 = 5;
const PLY_UINT: u8 = 6;
const PLY_FLOAT: u8 = 7;
const PLY_DOUBLE: u8 = 8;

type GsplRow = (
    (f64, f64, f64),
    (f64, f64, f64),
    f64,
    (f64, f64, f64),
    (f64, f64, f64, f64),
    Vec<f64>,
);

pub struct MappedSpatial {
    mmap: Mmap,
}

#[rustler::resource_impl]
impl Resource for MappedSpatial {}

fn nil_term(env: Env) -> Term {
    atom::nil().encode(env)
}

fn term_is_nil(term: Term) -> bool {
    term.decode::<atom::Atom>()
        .map(|a| a == atom::nil())
        .unwrap_or(false)
}

fn read_f32_le(data: &[u8], off: usize) -> Option<f32> {
    data.get(off..off + 4)
        .and_then(|b| b.try_into().ok())
        .map(f32::from_le_bytes)
}

fn read_f32_be(data: &[u8], off: usize) -> Option<f32> {
    data.get(off..off + 4)
        .and_then(|b| b.try_into().ok())
        .map(f32::from_be_bytes)
}

fn read_f64_le(data: &[u8], off: usize) -> Option<f64> {
    data.get(off..off + 8)
        .and_then(|b| b.try_into().ok())
        .map(f64::from_le_bytes)
}

fn read_f64_be(data: &[u8], off: usize) -> Option<f64> {
    data.get(off..off + 8)
        .and_then(|b| b.try_into().ok())
        .map(f64::from_be_bytes)
}

fn read_i16_le(data: &[u8], off: usize) -> Option<i16> {
    data.get(off..off + 2)
        .and_then(|b| b.try_into().ok())
        .map(i16::from_le_bytes)
}

fn read_i16_be(data: &[u8], off: usize) -> Option<i16> {
    data.get(off..off + 2)
        .and_then(|b| b.try_into().ok())
        .map(i16::from_be_bytes)
}

fn read_u16_le(data: &[u8], off: usize) -> Option<u16> {
    data.get(off..off + 2)
        .and_then(|b| b.try_into().ok())
        .map(u16::from_le_bytes)
}

fn read_u16_be(data: &[u8], off: usize) -> Option<u16> {
    data.get(off..off + 2)
        .and_then(|b| b.try_into().ok())
        .map(u16::from_be_bytes)
}

fn read_i32_le(data: &[u8], off: usize) -> Option<i32> {
    data.get(off..off + 4)
        .and_then(|b| b.try_into().ok())
        .map(i32::from_le_bytes)
}

fn read_i32_be(data: &[u8], off: usize) -> Option<i32> {
    data.get(off..off + 4)
        .and_then(|b| b.try_into().ok())
        .map(i32::from_be_bytes)
}

fn read_u32_le(data: &[u8], off: usize) -> Option<u32> {
    data.get(off..off + 4)
        .and_then(|b| b.try_into().ok())
        .map(u32::from_le_bytes)
}

fn read_u32_be(data: &[u8], off: usize) -> Option<u32> {
    data.get(off..off + 4)
        .and_then(|b| b.try_into().ok())
        .map(u32::from_be_bytes)
}

fn excp_stride(flags: u16) -> usize {
    let color = if flags & FLAG_ALPHA != 0 {
        4
    } else if flags & FLAG_COLOR != 0 {
        3
    } else {
        0
    };
    let normal = if flags & FLAG_NORMAL != 0 { 12 } else { 0 };
    12 + color + normal
}

fn gspl_stride(sh_rest: u16) -> usize {
    56 + (sh_rest as usize) * 4
}

fn ply_type_size(t: u8) -> Option<usize> {
    match t {
        PLY_CHAR | PLY_UCHAR => Some(1),
        PLY_SHORT | PLY_USHORT => Some(2),
        PLY_INT | PLY_UINT | PLY_FLOAT => Some(4),
        PLY_DOUBLE => Some(8),
        _ => None,
    }
}

fn ply_stride(types: &[u8]) -> Option<usize> {
    let mut n = 0usize;
    for t in types {
        n = n.checked_add(ply_type_size(*t)?)?;
    }
    Some(n)
}

fn ok_chunk<'a>(env: Env<'a>, records: Vec<Term<'a>>, next_offset: u64) -> Term<'a> {
    (atoms::ok(), (records, next_offset)).encode(env)
}

fn decode_excp_point<'a>(
    env: Env<'a>,
    data: &[u8],
    mut off: usize,
    flags: u16,
) -> Option<(Term<'a>, usize)> {
    let x = read_f32_le(data, off)? as f64;
    let y = read_f32_le(data, off + 4)? as f64;
    let z = read_f32_le(data, off + 8)? as f64;
    off += 12;

    let color = if flags & FLAG_ALPHA != 0 {
        let r = *data.get(off)? as i64;
        let g = *data.get(off + 1)? as i64;
        let b = *data.get(off + 2)? as i64;
        let a = *data.get(off + 3)? as i64;
        off += 4;
        (r, g, b, a).encode(env)
    } else if flags & FLAG_COLOR != 0 {
        let r = *data.get(off)? as i64;
        let g = *data.get(off + 1)? as i64;
        let b = *data.get(off + 2)? as i64;
        off += 3;
        (r, g, b).encode(env)
    } else {
        nil_term(env)
    };

    let normal = if flags & FLAG_NORMAL != 0 {
        let nx = read_f32_le(data, off)? as f64;
        let ny = read_f32_le(data, off + 4)? as f64;
        let nz = read_f32_le(data, off + 8)? as f64;
        off += 12;
        (nx, ny, nz).encode(env)
    } else {
        nil_term(env)
    };

    Some(((x, y, z, color, normal).encode(env), off))
}

fn unpack_excp_slice<'a>(
    env: Env<'a>,
    data: &[u8],
    flags: u16,
    offset: usize,
    max_count: usize,
) -> Term<'a> {
    let stride = excp_stride(flags);
    let mut off = offset;
    let mut records = Vec::with_capacity(max_count.min(8192));

    for _ in 0..max_count {
        if off.saturating_add(stride) > data.len() {
            break;
        }
        match decode_excp_point(env, data, off, flags) {
            Some((term, next)) => {
                records.push(term);
                off = next;
            }
            None => return err(env, atoms::invalid_data()),
        }
    }

    ok_chunk(env, records, off as u64)
}

fn decode_gspl_point<'a>(
    env: Env<'a>,
    data: &[u8],
    mut off: usize,
    sh_rest: u16,
) -> Option<(Term<'a>, usize)> {
    let mut vals = [0.0f64; 14];
    for v in &mut vals {
        *v = read_f32_le(data, off)? as f64;
        off += 4;
    }

    let mut sh = Vec::with_capacity(sh_rest as usize);
    for _ in 0..sh_rest {
        sh.push(read_f32_le(data, off)? as f64);
        off += 4;
    }

    // Nested tuples stay within Rustler's Encoder arity limits.
    let term = (
        (vals[0], vals[1], vals[2]),
        (vals[3], vals[4], vals[5]),
        vals[6],
        (vals[7], vals[8], vals[9]),
        (vals[10], vals[11], vals[12], vals[13]),
        sh,
    )
        .encode(env);
    Some((term, off))
}

fn unpack_gspl_slice<'a>(
    env: Env<'a>,
    data: &[u8],
    sh_rest: u16,
    offset: usize,
    max_count: usize,
) -> Term<'a> {
    let stride = gspl_stride(sh_rest);
    let mut off = offset;
    let mut records = Vec::with_capacity(max_count.min(8192));

    for _ in 0..max_count {
        if off.saturating_add(stride) > data.len() {
            break;
        }
        match decode_gspl_point(env, data, off, sh_rest) {
            Some((term, next)) => {
                records.push(term);
                off = next;
            }
            None => return err(env, atoms::invalid_data()),
        }
    }

    ok_chunk(env, records, off as u64)
}

fn decode_ply_value<'a>(
    env: Env<'a>,
    data: &[u8],
    off: usize,
    ty: u8,
    little: bool,
) -> Option<(Term<'a>, usize)> {
    match ty {
        PLY_CHAR => {
            let v = *data.get(off)? as i8 as i64;
            Some((v.encode(env), off + 1))
        }
        PLY_UCHAR => {
            let v = *data.get(off)? as i64;
            Some((v.encode(env), off + 1))
        }
        PLY_SHORT => {
            let v = if little {
                read_i16_le(data, off)?
            } else {
                read_i16_be(data, off)?
            } as i64;
            Some((v.encode(env), off + 2))
        }
        PLY_USHORT => {
            let v = if little {
                read_u16_le(data, off)?
            } else {
                read_u16_be(data, off)?
            } as i64;
            Some((v.encode(env), off + 2))
        }
        PLY_INT => {
            let v = if little {
                read_i32_le(data, off)?
            } else {
                read_i32_be(data, off)?
            } as i64;
            Some((v.encode(env), off + 4))
        }
        PLY_UINT => {
            let v = if little {
                read_u32_le(data, off)?
            } else {
                read_u32_be(data, off)?
            } as i64;
            Some((v.encode(env), off + 4))
        }
        PLY_FLOAT => {
            let v = if little {
                read_f32_le(data, off)?
            } else {
                read_f32_be(data, off)?
            } as f64;
            Some((v.encode(env), off + 4))
        }
        PLY_DOUBLE => {
            let v = if little {
                read_f64_le(data, off)?
            } else {
                read_f64_be(data, off)?
            };
            Some((v.encode(env), off + 8))
        }
        _ => None,
    }
}

fn unpack_ply_slice<'a>(
    env: Env<'a>,
    data: &[u8],
    types: &[u8],
    little: bool,
    offset: usize,
    max_count: usize,
) -> Term<'a> {
    let Some(stride) = ply_stride(types) else {
        return err(env, atoms::invalid_options());
    };

    let mut off = offset;
    let mut records = Vec::with_capacity(max_count.min(8192));

    for _ in 0..max_count {
        if off.saturating_add(stride) > data.len() {
            break;
        }
        let start = off;
        let mut row = Vec::with_capacity(types.len());
        for ty in types {
            match decode_ply_value(env, data, off, *ty, little) {
                Some((term, next)) => {
                    row.push(term);
                    off = next;
                }
                None => return err(env, atoms::invalid_data()),
            }
        }
        if off - start != stride {
            return err(env, atoms::invalid_data());
        }
        records.push(row.encode(env));
    }

    ok_chunk(env, records, off as u64)
}

fn write_f32_le(buf: &mut Vec<u8>, v: f64) {
    buf.extend_from_slice(&(v as f32).to_le_bytes());
}

fn clamp_u8(v: i64) -> u8 {
    v.clamp(0, 255) as u8
}

/// Point term: `{x, y, z, color, normal}` with color/normal nil or tuples.
fn pack_excp_point(buf: &mut Vec<u8>, term: Term, flags: u16) -> Result<(), ()> {
    let (x, y, z, color, normal): (f64, f64, f64, Term, Term) = term.decode().map_err(|_| ())?;
    write_f32_le(buf, x);
    write_f32_le(buf, y);
    write_f32_le(buf, z);

    if flags & FLAG_ALPHA != 0 {
        let (r, g, b, a) = if term_is_nil(color) {
            (0i64, 0, 0, 255)
        } else if let Ok((r, g, b, a)) = color.decode::<(i64, i64, i64, i64)>() {
            (r, g, b, a)
        } else if let Ok((r, g, b)) = color.decode::<(i64, i64, i64)>() {
            (r, g, b, 255)
        } else {
            return Err(());
        };
        buf.extend_from_slice(&[clamp_u8(r), clamp_u8(g), clamp_u8(b), clamp_u8(a)]);
    } else if flags & FLAG_COLOR != 0 {
        let (r, g, b) = if term_is_nil(color) {
            (0i64, 0, 0)
        } else if let Ok((r, g, b, _)) = color.decode::<(i64, i64, i64, i64)>() {
            (r, g, b)
        } else if let Ok((r, g, b)) = color.decode::<(i64, i64, i64)>() {
            (r, g, b)
        } else {
            return Err(());
        };
        buf.extend_from_slice(&[clamp_u8(r), clamp_u8(g), clamp_u8(b)]);
    }

    if flags & FLAG_NORMAL != 0 {
        let (nx, ny, nz) = if term_is_nil(normal) {
            (0.0, 0.0, 0.0)
        } else {
            normal.decode::<(f64, f64, f64)>().map_err(|_| ())?
        };
        write_f32_le(buf, nx);
        write_f32_le(buf, ny);
        write_f32_le(buf, nz);
    }

    Ok(())
}

fn pack_gspl_point(buf: &mut Vec<u8>, term: Term, sh_rest: u16) -> Result<(), ()> {
    let (pos, color, opacity, scale, rot, sh): GsplRow = term.decode().map_err(|_| ())?;

    let (x, y, z) = pos;
    let (r, g, b) = color;
    let (sx, sy, sz) = scale;
    let (rw, rx, ry, rz) = rot;

    for v in [x, y, z, r, g, b, opacity, sx, sy, sz, rw, rx, ry, rz] {
        write_f32_le(buf, v);
    }

    for i in 0..sh_rest as usize {
        write_f32_le(buf, sh.get(i).copied().unwrap_or(0.0));
    }

    Ok(())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn excp_unpack<'a>(
    env: Env<'a>,
    data: Binary,
    flags: u16,
    offset: u64,
    max_count: u64,
) -> Term<'a> {
    unpack_excp_slice(
        env,
        data.as_slice(),
        flags,
        offset as usize,
        max_count as usize,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn excp_pack<'a>(env: Env<'a>, records: Vec<Term>, flags: u16) -> Term<'a> {
    let mut buf = Vec::with_capacity(records.len().saturating_mul(excp_stride(flags)));
    for term in records {
        if pack_excp_point(&mut buf, term, flags).is_err() {
            return err(env, atoms::invalid_data());
        }
    }
    ok_binary(env, &buf)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn gspl_unpack<'a>(
    env: Env<'a>,
    data: Binary,
    sh_rest: u16,
    offset: u64,
    max_count: u64,
) -> Term<'a> {
    unpack_gspl_slice(
        env,
        data.as_slice(),
        sh_rest,
        offset as usize,
        max_count as usize,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn gspl_pack<'a>(env: Env<'a>, records: Vec<Term>, sh_rest: u16) -> Term<'a> {
    let mut buf = Vec::with_capacity(records.len().saturating_mul(gspl_stride(sh_rest)));
    for term in records {
        if pack_gspl_point(&mut buf, term, sh_rest).is_err() {
            return err(env, atoms::invalid_data());
        }
    }
    ok_binary(env, &buf)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ply_binary_unpack<'a>(
    env: Env<'a>,
    data: Binary,
    types: Vec<u8>,
    little_endian: bool,
    offset: u64,
    max_count: u64,
) -> Term<'a> {
    unpack_ply_slice(
        env,
        data.as_slice(),
        &types,
        little_endian,
        offset as usize,
        max_count as usize,
    )
}

#[rustler::nif(schedule = "DirtyIo")]
fn spatial_mmap_open<'a>(env: Env<'a>, path: String) -> Term<'a> {
    // Caller must not truncate/replace the file while the mmap resource is live
    // (SIGBUS can kill the BEAM). Prefer plain IO for untrusted paths.
    match File::open(&path).and_then(|f| unsafe { Mmap::map(&f) }) {
        Ok(mmap) => {
            let resource = ResourceArc::new(MappedSpatial { mmap });
            (atoms::ok(), resource).encode(env)
        }
        Err(_) => err(env, atoms::io_error()),
    }
}

#[rustler::nif]
fn spatial_mmap_len(resource: ResourceArc<MappedSpatial>) -> NifResult<u64> {
    Ok(resource.mmap.len() as u64)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn excp_unpack_mmap<'a>(
    env: Env<'a>,
    resource: ResourceArc<MappedSpatial>,
    flags: u16,
    offset: u64,
    max_count: u64,
) -> Term<'a> {
    unpack_excp_slice(
        env,
        &resource.mmap,
        flags,
        offset as usize,
        max_count as usize,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn gspl_unpack_mmap<'a>(
    env: Env<'a>,
    resource: ResourceArc<MappedSpatial>,
    sh_rest: u16,
    offset: u64,
    max_count: u64,
) -> Term<'a> {
    unpack_gspl_slice(
        env,
        &resource.mmap,
        sh_rest,
        offset as usize,
        max_count as usize,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ply_binary_unpack_mmap<'a>(
    env: Env<'a>,
    resource: ResourceArc<MappedSpatial>,
    types: Vec<u8>,
    little_endian: bool,
    offset: u64,
    max_count: u64,
) -> Term<'a> {
    unpack_ply_slice(
        env,
        &resource.mmap,
        &types,
        little_endian,
        offset as usize,
        max_count as usize,
    )
}

/// Append packed body bytes to a file (chunked encode helper).
#[rustler::nif(schedule = "DirtyIo")]
fn spatial_append_file<'a>(env: Env<'a>, path: String, data: Binary) -> Term<'a> {
    match File::options().append(true).create(true).open(&path) {
        Ok(mut file) => match file.write_all(data.as_slice()) {
            Ok(()) => atoms::ok().encode(env),
            Err(_) => err(env, atoms::io_error()),
        },
        Err(_) => err(env, atoms::io_error()),
    }
}
