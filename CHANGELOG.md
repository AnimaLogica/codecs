# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.4] - unreleased

### Added

- `:blosc` codec (`ExCodecs.Compression.Blosc`): Blosc1 chunks in the c-blosc
  1.x wire format, as read and written by numcodecs, zarr-python and the Zarr
  v2/v3 `blosc` codec. Pure Rust; all compressors except Snappy, byte and bit
  shuffle. Output is verified to decode in c-blosc 1.21.
- `:crc32c` codec (`ExCodecs.Checksum.Crc32c`): appends / verifies a
  little-endian CRC32C (Zarr v3 `crc32c`), plus `Crc32c.checksum/1`.
- `:checksum_mismatch` error reason.
- `mix nif.verify_checksums`, run automatically before `mix hex.publish`.

### Fixed

- The 0.2.3 package on Hex has an empty `checksum-Elixir.ExCodecs.Native.exs`,
  so precompiled NIFs cannot be downloaded and installs fail without a Rust
  toolchain. CI published a correct package, which a local `mix hex.publish`
  then replaced. `mix hex.publish` now refuses to run unless the checksum file
  covers every target for the current version.
- NIF `:truncated_input` errors were reported as `:invalid_data`.

### Notes

- `:blosc2` writes the Blosc2 chunk format, which c-blosc 1.x (numcodecs,
  zarr-python) cannot read. Use `:blosc` for Zarr data.

## [0.2.3] - 2026-07-18

### Added

- **Incremental spatial file I/O** — EXCP (`:spatial_binary`), GSPL (`:gsplat`),
  and PLY `stream_decode` with `source: :file` (or `:auto` path detection) read
  the header then **one record/vertex at a time** from disk (bounded memory).
  Binary PLY uses a fixed stride; ASCII PLY reads lines.
- `Binary.stream_encode_to_file/3` and `Gsplat.stream_encode_to_file/3` —
  incremental file writes with an explicit `:schema` (placeholder header,
  seek-back count). `Spatial.Stream.encode_to_file/3` uses these when
  `:schema` is present with `format: :spatial_binary` or `:gsplat`.
- **Spatial Rust acceleration** (DirtyCpu NIFs): chunked EXCP/GSPL pack &
  unpack, mmap-backed file `stream_decode`, binary PLY body unpack, and
  chunked `stream_encode_to_file`. Pass `accel: false` to force pure Elixir.
  Property tests compare both backends byte-for-byte / structurally.

### Changed

- Mix `preferred_cli_env` moved into `cli/0` (`preferred_envs`) for Mix 1.20+.
- In-memory spatial `stream_decode` uses chunked Rust unpack when the spatial
  NIF is loaded; otherwise it still materializes through `decode/2`.

### Notes

- Wire layouts for EXCP / GSPL / PLY remain the **v0.2.0 freeze** in
  `docs/spatial_formats.md` (Rust output is byte-compatible).
- Precompiled NIF checksums must be regenerated when publishing GitHub release
  artifacts for `0.2.3`.

## [0.2.2] - 2026-07-17

### Notes

- Version number reserved and **superseded; not published** to Hex.pm. The
  work intended for 0.2.2 was rolled into 0.2.3 (spatial streaming and Rust
  acceleration) instead. Recorded per [Keep a Changelog](https://keepachangelog.com)
  so the version-skip is not silent.

## [0.2.1] - 2026-07-17

### Fixed

- README links and badge URLs corrected following the 0.2.0 spatial release.
- `mix.exs` version bump to 0.2.1.

## [0.2.0] - 2026-07-16

### Added

- **`ExCodecs.Spatial`** — new spatial codec category for point clouds and
  Gaussian splats (pure Elixir, no rendering).
- Domain types: `Point`, `PointCloud`, `Gaussian`, `GaussianCloud`, `Bounds`,
  `Transform`, `Metadata`.
- Format codecs:
  - `:ply` — ASCII and binary PLY (XYZ / RGB / RGBA / normals / attributes,
    plus Gaussian PLY conventions)
  - `:spatial_binary` — compact `EXCP` binary point clouds
  - `:gsplat` — simple `GSPL` binary Gaussian format
- Streaming helpers: `ExCodecs.stream_decode/2`, `ExCodecs.stream_encode/2`,
  and `ExCodecs.Spatial.Stream` (materializing streams; optional `source: :file | :binary`).
- Spatial category module `ExCodecs.Spatial` (struct↔format); top-level
  `ExCodecs.encode/3` / `decode/3` remain **registry binary codecs only**
  (original framework shape). `stream_encode` / `stream_decode` on `ExCodecs`
  delegate to Spatial for convenience.
- Example datasets under `priv/examples/spatial/`.
- Guide: `guides/understanding_spatial_codecs.md`.
- Wire-format freeze: `docs/spatial_formats.md` (EXCP / GSPL / PLY rules).
- Spatial tutorial Livebook: `livebooks/06_spatial_codecs.livemd`; existing
  Livebooks now target v0.2.0 APIs and metadata.
- Shared codec catalog discovery across compression and spatial categories,
  including `ExCodecs.available_codecs/1` and `%ExCodecs.Codec{interface: ...}`.
- Registry `unregister/1` and re-registration on registry process restart.
- Error reasons `:io_error`, `:truncated_input`, and `:output_limit_exceeded`.
- Decode option `:max_output_size` (default **256 MiB**) on all compression
  codecs — rejects decompression bombs.

### Changed

- **Native NIF is pure Rust** — no C compression libraries:
  - Zstd via `structured-zstd` (not libzstd / not stock `ruzstd` encoder)
  - Bzip2 via `bzip2` + pure-Rust `libbz2-rs-sys`
  - Zlib (Blosc2 inner) via `flate2` rust backend
  - LZ4 / Snappy unchanged pure crates
- **Zstd `:level`** (1–22) is functional on the pure-Rust encoder (ratios may
  differ from C libzstd at the same numeric level).
- **Blosc2**: C-Blosc2-compatible **chunk** format via pure-Rust `blosc2-pure-rs`
  (`:blosclz`, `:lz4`, `:lz4hc`, `:zstd`, `:zlib` + shuffle/bitshuffle).
  Golden tests against python-blosc2 fixtures.
- Codec `streaming?` metadata set to `false` until real streaming exists.
- Removed unimplemented Zstd `:window_log` option from docs.
- NIF load checked at registration; NIF calls wrapped so `:nif_not_loaded`
  becomes `{:error, %ExCodecs.Error{}}` instead of raising.
- Safer PLY header parsing (no raise on malformed element lines / unknown types).
- Point attributes normalized to **string keys** (atoms accepted at `Point.new/4`).
- Public API docs cover spatial formats alongside compression codecs.
- Spatial encode/decode resolves PLY, EXCP, and GSPL implementations through
  the shared ETS catalog while retaining the category-safe Spatial API.
- Test coverage threshold restored to **95%** after expanding spatial and NIF
  edge-case coverage.

### Notes

- `native/ex_codecs_native/Cargo.lock` is committed for reproducible NIF builds.

## [0.1.1] - 2026-06-15

### Added

- **Blosc2 bit shuffle support** — `shuffle: :bit` option for `ExCodecs.encode(:blosc2, ...)`,
  providing better compression on certain data patterns beyond the existing `:none` and `:byte`
  shuffle modes (#20).

### Fixed

- **Livebook 02** — Fixed `Jason.encode!/1` wrapping for-comprehensions in `%{}` (#21).
- **Livebook 02** — Wrapped for-comprehensions in parentheses inside map values.
- **Livebook 03** — Removed `Kino.VegaLite.new()` calls (Livebook auto-renders VegaLite pipelines).
- **Livebook 03** — Fixed `Kino.Input.select` to use keyword lists (`atom: "label"`) instead
  of maps.
- **Livebook 03** — Added `Kino.render()` wrapper for `Kino.Layout.grid()` widget.
- **Livebook 04** — Rewrote entirely: fixed broken markdown/code cell boundaries, moved
  top-level `def` calls into `defmodule` blocks, fixed `Agent.get_and_update` state
  corruption (was replacing struct with bare map), added `Kino`/`kino_vega_lite` deps.
- **Livebook 05** — Added `kino_vega_lite` dep for proper VegaLite rendering.

### Changed

- All livebooks now use **conditional Mix.install** setup cells that detect whether the
  project is being run locally (from the repo) or published (from Hex.pm). Local
  development uses `path:` deps with `rustler` and `force_build`; published livebooks
  use `{:ex_codecs, "~> 0.1.1"}` with pre-compiled NIFs.
- README badges updated with CI, Hex.pm, docs, license, Elixir version, and Coveralls
  coverage links.

## [0.1.0] - 2026-06-13

### Added

- Initial release of ExCodecs.
- Unified `encode/3` and `decode/3` API across all codecs.
- Codec registry with `available_codecs/0`, `supports?/1`, `codec_info/1`.
- Five compression codecs: Zstd, LZ4, Snappy, Bzip2, Blosc2.
- Blosc2 shuffle support (`:none`, `:byte`).
- Rust NIF implementation via `rustler_precompiled`.
- Precompiled binaries for macOS (ARM64, x86_64), Linux (glibc, musl, ARM64), Windows (x86_64).
- `ExCodecs.Compression` convenience module (`compress/3`, `decompress/3`).
- Structured error handling with `%ExCodecs.Error{}`.
- CI pipeline (test matrix, lint, coverage, docs).
- Release workflow for Hex.pm publishing with precompiled NIFs.
- Five livebooks: introduction, fundamentals, comparison, storage systems, Zarr workloads.
- Eleven guides covering all public modules and API details.
- Benchmarks via benchee.
- Credo and Dialyzer integration.

[Unreleased]: https://github.com/AnimaLogica/codecs/compare/v0.2.4...HEAD
[0.2.4]: https://github.com/AnimaLogica/codecs/releases/tag/v0.2.4
[0.2.3]: https://github.com/AnimaLogica/codecs/releases/tag/v0.2.3
[0.2.2]: https://github.com/AnimaLogica/codecs/releases/tag/v0.2.2
[0.2.1]: https://github.com/AnimaLogica/codecs/releases/tag/v0.2.1
[0.2.0]: https://github.com/AnimaLogica/codecs/releases/tag/v0.2.0
[0.1.1]: https://github.com/AnimaLogica/codecs/releases/tag/v0.1.1
[0.1.0]: https://github.com/AnimaLogica/codecs/releases/tag/v0.1.0