# ExCodecs

[![CI](https://github.com/AnimaLogica/codecs/actions/workflows/ci.yml/badge.svg)](https://github.com/AnimaLogica/codecs/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/ex_codecs.svg)](https://hex.pm/packages/ex_codecs)
[![Hex.pm Downloads](https://img.shields.io/hexpm/dt/ex_codecs.svg)](https://hex.pm/packages/ex_codecs)
[![Documentation](https://img.shields.io/badge/docs-hex.pm-blue.svg)](https://hexdocs.pm/ex_codecs)
[![License](https://img.shields.io/hexpm/l/ex_codecs.svg)](https://github.com/AnimaLogica/codecs/blob/main/LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-%7E%3E%201.17-purple.svg)](https://elixir-lang.org)
[![Coverage Status](https://coveralls.io/repos/github/AnimaLogica/codecs/badge.svg?branch=main)](https://coveralls.io/github/AnimaLogica/codecs?branch=main)

An extensible BEAM-native codec framework for Elixir with specialized category
APIs. Binary registry codecs use `ExCodecs.encode/3` / `decode/3`;
`ExCodecs.Spatial` handles point-cloud and Gaussian domain types.

**Blosc2** produces C-Blosc2-compatible **chunks** only (not super-chunk /
B2ND / `.b2frame`). Standalone `:snappy` is separate from Blosc2 `cname:`.

## Design Philosophy

ExCodecs is not a compression library. It is a codec framework.

Compression and spatial formats are categories in one framework. Each category
uses an API shaped for its data:

- Binary→binary registry codecs implement `ExCodecs.Codec` and use
  `ExCodecs.encode/3` / `decode/3`.
- Spatial struct↔format codecs use `ExCodecs.Spatial`.

Discovery is category-specific: `ExCodecs.available_codecs/0` lists registered
binary codecs, while `ExCodecs.Spatial.available_formats/0` lists spatial
formats. This keeps one framework and error model without forcing unlike data
shapes through an overloaded function.

The `encode`/`decode` naming is category-agnostic: for compression codecs,
encoding is compressing and decoding is decompressing; for a future hash codec,
encoding would produce a digest and decoding would verify it.

## Installation

Add `ex_codecs` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_codecs, "~> 0.2.3"}
  ]
end
```

Then fetch dependencies and compile:

```sh
mix deps.get && mix compile
```

Precompiled NIF binaries are available for macOS (Intel and ARM64), Linux
(x86_64 and ARM64, glibc and musl), and Windows (x86_64). They are downloaded
automatically from the [GitHub releases](https://github.com/AnimaLogica/codecs/releases)
when you run `mix deps.get`. If a precompiled artifact is not available for your
target, ExCodecs falls back to compiling the Rust NIF from source (requires
Rust 1.94+). The native crate is **pure Rust** (no C toolchain / system
compression libraries).

## Quick Start

```elixir
# Registry codecs (primary API — always codec atom + binary)
{:ok, compressed} = ExCodecs.encode(:zstd, "hello world")
{:ok, original}  = ExCodecs.decode(:zstd, compressed)
original #=> "hello world"

{:ok, compressed} = ExCodecs.encode(:zstd, my_binary, level: 9)
{:ok, compressed} = ExCodecs.encode(:blosc2, my_binary, cname: :zstd, clevel: 5, shuffle: :byte)

# Category alias for compression
{:ok, compressed} = ExCodecs.Compression.compress(:lz4, data)
{:ok, original}   = ExCodecs.Compression.decompress(:lz4, compressed)

# Shared discovery
ExCodecs.available_codecs()  #=> [:blosc, :blosc2, :bzip2, :crc32c, :gsplat, :lz4, :ply, :snappy, :spatial_binary, :zstd]
ExCodecs.available_codecs(:compression) #=> [:blosc, :blosc2, :bzip2, :lz4, :snappy, :zstd]
ExCodecs.available_codecs(:spatial)     #=> [:gsplat, :ply, :spatial_binary]
ExCodecs.supports?(:zstd)    #=> true
ExCodecs.codec_info(:zstd)   #=> {:ok, %ExCodecs.Codec{name: :zstd, category: :compression, ...}}

# Spatial category API (structs ↔ formats)
alias ExCodecs.Spatial.{Point, PointCloud}
cloud = PointCloud.new([Point.new(0.0, 0.0, 0.0, color: {255, 0, 0})])
{:ok, ply} = ExCodecs.Spatial.encode(cloud, format: :ply)
{:ok, cloud} = ExCodecs.Spatial.decode(ply, format: :ply)
ExCodecs.Spatial.stream_decode(ply, format: :ply) |> Enum.to_list()
ExCodecs.Spatial.available_formats() #=> [:ply, :spatial_binary, :gsplat]
ExCodecs.codec_info(:ply) #=> {:ok, %ExCodecs.Codec{category: :spatial, interface: :spatial, ...}}
```

## API Overview

### Binary registry API

```elixir
{:ok, encoded} = ExCodecs.encode(:zstd, binary, level: 3)
{:ok, decoded} = ExCodecs.decode(:zstd, compressed)
```

The binary registry API is always **codec atom + binary**.

### Category APIs

- `ExCodecs.Compression.compress/3` — compression terminology over the binary
  registry API.
- `ExCodecs.Spatial.encode/2` / `decode/2` — point clouds and Gaussians
  (struct↔format).

These are specialized entry points in the same framework, sharing conventions
such as tagged results and `%ExCodecs.Error{}`.

### `encode/3` / `decode/3`

First argument is always a **codec atom**. Returns `{:ok, binary}` or
`{:error, %ExCodecs.Error{}}`.

### `available_codecs/0`

```elixir
ExCodecs.available_codecs()          # all available catalog entries
ExCodecs.available_codecs(:spatial) #=> [:gsplat, :ply, :spatial_binary]
```

Returns a sorted list of codec atoms that are both registered and have a
loaded implementation. Use `available_codecs/1` to filter the shared catalog
by category.

### `supports?/1`

```elixir
ExCodecs.supports?(:zstd)       #=> true
ExCodecs.supports?(:nonexistent) #=> false
```

Returns `true` only if the codec is registered **and** its native NIF is loaded.

### `codec_info/1`

```elixir
{:ok, info} = ExCodecs.codec_info(:zstd)
info.category       #=> :compression
info.native?        #=> true
info.streaming?     #=> false  # block API only today
info.configurable?  #=> true
info.version        #=> backend version string
```

Returns a structured `%ExCodecs.Codec{}` struct with metadata, or
`{:error, :unsupported_codec}`.

## Supported Codecs

| Codec     | Category    | Configurable | Streaming | Options                                        |
|-----------|-------------|--------------|-----------|------------------------------------------------|
| `:zstd`   | compression | Yes           | No         | `level` 1-22 (pure-Rust `structured-zstd`); `max_output_size` (default 256 MiB) |
| `:lz4`    | compression | No            | No         | size-prepended `lz4_flex`; `max_output_size` |
| `:snappy` | compression | No            | No         | `max_output_size` |
| `:bzip2`  | compression | Yes           | No         | `block_size` 1-9; `max_output_size` |
| `:blosc`  | compression | Yes           | No         | **Blosc1 chunk** (c-blosc 1.x / numcodecs / Zarr). `cname` / `clevel` / `shuffle` / `typesize`; `max_output_size` |
| `:blosc2` | compression | Yes           | No         | C-Blosc2 **chunk** only. `cname` / `clevel` / `shuffle` / `typesize`; `max_output_size` |
| `:crc32c` | checksum    | No            | No         | Appends / verifies a little-endian CRC32C (Zarr v3 `crc32c`) |

### Spatial formats

| Format            | Types                         | Notes                                              |
|-------------------|-------------------------------|----------------------------------------------------|
| `:ply`            | PointCloud / GaussianCloud    | ASCII or binary PLY; Gaussian PLY properties       |
| `:spatial_binary` | PointCloud                    | Compact little-endian `EXCP` container             |
| `:gsplat`         | GaussianCloud                 | Compact little-endian `GSPL` container             |

See [Understanding Spatial Codecs](https://hexdocs.pm/ex_codecs/understanding_spatial_codecs.html)
and the frozen [Spatial wire formats](https://hexdocs.pm/ex_codecs/spatial_formats.html).

### Known limitations

- **Zstd** uses pure-Rust `structured-zstd`. Levels 1–22 work, but compressed
  bytes/ratios are not guaranteed identical to C libzstd.
- **Decompression** defaults to a **256 MiB** `max_output_size`. Raise it only
  for trusted inputs; do not decompress untrusted payloads without a tight limit.
- Spatial **file** `stream_decode` is incremental (bounded memory). In-memory
  binaries use chunked Rust unpack when available, otherwise materialize.
  `stream_encode/2` still collects the enumerable, then encodes once; use
  `encode_to_file/3` with an explicit `:schema` for EXCP/GSPL file streaming.

## Architecture

ExCodecs is layered as follows:

1. **Category APIs** — `ExCodecs` provides the binary registry API;
   `ExCodecs.Compression` adds compression terminology; `ExCodecs.Spatial`
   handles spatial domain types and formats.

2. **Codec Behaviour** (`ExCodecs.Codec`) — `encode/2` / `decode/2` on binaries;
   optional `__codec_info__/0` for registry metadata.

3. **Shared codec catalog** (`ExCodecs.CodecRegistry`) — ETS map of codec atoms
   to modules, categories, interface shapes, and metadata, populated at startup.

4. **Native NIFs** (`ExCodecs.Native`) — pure-Rust compression plus optional
   spatial DirtyCpu / mmap acceleration via `rustler_precompiled` (or local
   compile).

5. **Category discovery** — `available_codecs/0` lists the whole catalog;
   `available_codecs/1` filters it, and
   `ExCodecs.Spatial.available_formats/0` provides the spatial category's
   preferred built-in order.

To add a binary codec: implement `ExCodecs.Codec`, wire a NIF if needed, and
register it with `interface: :binary`. Spatial implementations live under
`ExCodecs.Spatial` and register with `category: :spatial` and
`interface: :spatial`.

## Error Handling

All public functions return `{:ok, result}` or `{:error, %ExCodecs.Error{}}`.
Error reasons are atoms:

| Reason                | Meaning                                          |
|-----------------------|--------------------------------------------------|
| `:unsupported_codec`  | The codec name is not registered                 |
| `:codec_unavailable`  | Registered but the native NIF failed to load    |
| `:invalid_data`       | Data is not a binary or is otherwise invalid     |
| `:invalid_options`    | Options are out of range or malformed            |
| `:compression_failed` | The underlying compression operation failed      |
| `:decompression_failed`| The underlying decompression operation failed   |
| `:nif_not_loaded`     | The NIF library could not be loaded              |
| `:io_error`           | File read/write failure                          |
| `:truncated_input`    | Incomplete binary                                |
| `:output_limit_exceeded` | Decompress would exceed `max_output_size`     |

```elixir
{:error, error} = ExCodecs.encode(:unknown, "data")
error.reason  #=> :unsupported_codec

{:error, error} = ExCodecs.encode(:zstd, "data", level: 99)
error.reason  #=> :invalid_options
```

## Benchmarking

ExCodecs includes benchmarking utilities via [benchee](https://github.com/bencheeorg/benchee).

```sh
# Run all compression benchmarks
mix benchmarks
```

Benchmarks are defined in `bench/` and run in the `:bench` environment. Results
are saved to `bench/results/` (git-ignored).

## Development

```sh
# Fetch dependencies and compile (includes NIF compilation)
mix deps.get && mix compile

# Run the full test suite
mix test

# Run tests with coverage
mix coveralls

# Run static analysis
mix credo
mix dialyzer

# Format code
mix format

# Lint Rust NIF code
mix rust.lint

# Run Rust NIF tests
mix rust.test

# Generate documentation
mix docs
```

### Requirements

- Elixir 1.17+
- Erlang/OTP 26+
- Rust 1.94+ (only required if precompiled NIFs are unavailable for your platform)

## License

Apache License, Version 2.0. See [LICENSE](LICENSE) for details.