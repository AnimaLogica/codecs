# Native Architecture

ExCodecs implements compression and spatial unpack/pack in a Rust NIF crate
(`native/ex_codecs_native`), loaded through
[`RustlerPrecompiled`](https://github.com/philss/rustler_precompiled). This guide
describes the current crate layout, Dirty scheduler use, precompiled
distribution, and how Elixir wraps NIF results.

## Why a NIF?

Compression and dense binary spatial decode are CPU-bound over large binaries.
Doing that work in Rust lets the library:

- Operate on contiguous `&[u8]` slices without BEAM binary traversal cost
- Use mature pure-Rust codec crates (no C compression toolchain at build time)
- Offload long work to Dirty CPU / Dirty IO schedulers so normal BEAM
  schedulers stay responsive

There is **no** pure-Elixir Zstd/LZ4/Snappy/Bzip2/Blosc2 path. When the NIF is
absent, codecs register as unavailable and public APIs return
`%ExCodecs.Error{reason: :nif_not_loaded}`.

## Elixir entry point

`ExCodecs.Native` uses `RustlerPrecompiled` (not `use Rustler` alone):

```elixir
use RustlerPrecompiled,
  otp_app: :ex_codecs,
  crate: :ex_codecs_native,
  version: version,
  base_url: "https://github.com/AnimaLogica/codecs/releases/download/v#{version}",
  mode: :release,
  nif_versions: ["2.17"],
  targets: [
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
    "x86_64-unknown-linux-gnu",
    "x86_64-unknown-linux-musl",
    "aarch64-unknown-linux-gnu",
    "aarch64-unknown-linux-musl",
    "x86_64-pc-windows-msvc"
  ]
```

Each exported function has an Elixir stub that raises
`:erlang.nif_error(:nif_not_loaded)` until the shared library loads.
`ExCodecs.Native.nif_loaded?/0` probes `codec_versions/0`.

Public codecs never call `Native` stubs directly for error shaping: they go
through `ExCodecs.NIF.safe_call/2` / `wrap/2`, which map atoms and panics into
`%ExCodecs.Error{}`. Spatial codecs use `ExCodecs.Spatial.Accel` for the same
purpose.

## Rust crate layout

```
native/ex_codecs_native/
  Cargo.toml          # rust-version = "1.94", pure-Rust deps
  src/
    lib.rs            # rustler::init + codec_versions/0
    atoms.rs
    zstd_codec.rs     # structured-zstd
    lz4_codec.rs      # lz4_flex (size-prepended block)
    snappy_codec.rs   # snap (raw block)
    bzip2_codec.rs    # bzip2 0.6 (pure-Rust backend)
    blosc2_codec.rs   # blosc2-pure-rs
    spatial.rs        # EXCP / GSPL / PLY pack-unpack + mmap
    util.rs
```

Current compression dependencies (no C `libzstd` / `libbzip2` / c-blosc2):

```toml
structured-zstd = "0.0.48"
lz4_flex = "0.11"
snap = "1.1"
bzip2 = "0.6"
blosc2-pure-rs = { version = "0.2.4", features = ["zlib-rs"] }
memmap2 = "0.9"
```

Release profile: `opt-level = 3`, `lto = true`, `codegen-units = 1`, `strip = true`.

### Version map

`codec_versions/0` returns a string map of backend labels, including
`"spatial" => "excp-gspl-ply-1"`. Elixir codec modules may hardcode library
crate versions in `__codec_info__/0`; treat the NIF map as a runtime probe, not
the only source of truth for HexDocs metadata.

## Dirty scheduling

Dirty scheduling is **explicit** on each NIF (`#[rustler::nif(schedule = ...)]`).
Rustler does **not** auto-promote long NIFs.

| Kind | Examples |
|------|----------|
| `DirtyCpu` | All compress/decompress; EXCP/GSPL/PLY pack and unpack (binary + mmap) |
| `DirtyIo` | `spatial_mmap_open`, `spatial_append_file` |

Configure dirty CPU count with the VM flag `+SDcpu N` (not `-SDio`).

Implications:

1. Normal schedulers stay free while compression runs on dirty threads.
2. Concurrent NIF work is limited by dirty scheduler count.
3. A started NIF cannot be cancelled. Wrapping in `Task.yield/2` +
   `Task.shutdown/1` abandons the Elixir task; the dirty NIF may still finish
   and hold a dirty scheduler until it returns.

## Precompiled distribution

CI attaches platform binaries to the GitHub release matching the package
version. At `mix deps.get` / app start, RustlerPrecompiled downloads the
matching artifact when present; otherwise it compiles from
`native/ex_codecs_native` (requires Rust **1.94+**).

`nif_versions: ["2.17"]` matches OTP 26+ NIF ABI 2.17. Supported OTP releases
for this package are those listed in `mix.exs` / README; precompiled binaries
target that NIF version.

If load fails entirely, `ExCodecs.Application` registers codecs as unavailable
(`module: nil`) instead of crashing the VM.

## Error path

```
Rust Result::Err / atom
  -> Rustler {:error, atom} or ErlangError
  -> ExCodecs.NIF.wrap/2 or safe_call/2
  -> {:error, %ExCodecs.Error{}}
```

There is no `Error.from_nif/2` helper. Panic-like `ErlangError` payloads are
logged and returned as `:compression_failed` with message
`"Native codec crashed"`.

Decompression honors `:max_output_size` (default 256 MiB) to bound
amplification; see `ExCodecs.NIF` and `ExCodecs.Compression.decompress/3`.

## Spatial acceleration

`ExCodecs.Spatial.Accel` is the Elixir ABI over the spatial NIFs: row tuple
shapes, chunked unpack (`{rows, next_offset}`), pack, and mmap resources.

- Prefer `Accel.chunk_size/0` (4096) loops for large clouds.
- Do not truncate or replace a file while an mmap resource is live
  (possible SIGBUS). Use `accel: false` / plain IO for untrusted paths.
- When `Accel.available?/0` is false, codecs fall back to pure Elixir decode.

## Summary

- Pure-Rust compression crates behind RustlerPrecompiled NIFs
- Explicit DirtyCpu / DirtyIo scheduling
- Structured errors via `ExCodecs.NIF`, never raw exceptions on the public API
- Optional spatial accel with Elixir fallback and mmap safety caveats
