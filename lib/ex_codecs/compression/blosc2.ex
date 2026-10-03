defmodule ExCodecs.Compression.Blosc2 do
  @moduledoc """
  Blosc2 **chunk** codec — C-Blosc2-compatible wire format, pure Rust.

  ## What you get (chunk only)

  ```
  binary  →  [filters]  →  [codec]  →  one Blosc2 chunk binary
  ```

  This matches python-blosc2 / C-Blosc2 **single-buffer** compress/decompress.

  ### Not included

  | Layer | Status |
  |-------|--------|
  | Super-chunk (SChunk) | No |
  | Contiguous frame (`.b2frame`) | No |
  | B2ND (N-D arrays) | No |

  For large data, split buffers yourself and store multiple chunks. Usability
  for "compress my array slice in Elixir" is full; for "Blosc2 as a database
  file format", use python/C Blosc2.

  ## Options

    * `:cname` — `:blosclz` | `:lz4` (default) | `:lz4hc` | `:zstd` | `:zlib`
    * `:clevel` — `0..9` (default `5`)
    * `:shuffle` — `:none` | `:byte` (default) | `:bit`
    * `:typesize` — `1..255` (default `8`)
    * `:max_output_size` — Maximum allowed decompressed size in bytes
      (default: 256 MiB; also hard-capped at 1 GiB per chunk)

  ## Security

  Do not decompress untrusted inputs without a tight `:max_output_size`.

  ### Snappy

  `cname: :snappy` is **rejected**. Use standalone `ExCodecs.encode(:snappy, data)`
  or Blosc2 with `:lz4` / `:blosclz`.

  ## Implementation

  Pure-Rust `blosc2-pure-rs` (no C-Blosc2 / cmake). NIF uses single-threaded
  compression (`nthreads: 1`) on DirtyCpu.

  ## Examples

      iex> {:ok, compressed} = ExCodecs.encode(:blosc2, <<1, 2, 3, 4, 5, 6, 7, 8>>)
      iex> {:ok, decompressed} = ExCodecs.decode(:blosc2, compressed)
      iex> decompressed
      <<1, 2, 3, 4, 5, 6, 7, 8>>
  """

  @behaviour ExCodecs.Codec

  alias ExCodecs.Compression.BloscOptions

  @doc """
  Returns the registry metadata for the Blosc2 chunk codec.

  ## Arguments

  This function takes no arguments.

  ## Returns

  An `ExCodecs.Codec.t()` with these Blosc2-specific fields:

    * `name: :blosc2` and `category: :compression`
    * `module: ExCodecs.Compression.Blosc2`
    * `native?: true` because compression runs in a NIF
    * `streaming?: false` because only individual chunks are supported
    * `configurable?: true` because `encode/2` accepts compressor and filter
      options
    * `version: "c-blosc2-chunk/pure-rust"` for the compatible format and
      backend

  ## Raises / Exceptions

  This function does not invoke the NIF and does not raise.

  ## Examples

      iex> ExCodecs.Compression.Blosc2.__codec_info__()
      %ExCodecs.Codec{
        name: :blosc2,
        category: :compression,
        module: ExCodecs.Compression.Blosc2,
        native?: true,
        streaming?: false,
        configurable?: true,
        version: "c-blosc2-chunk/pure-rust"
      }
  """
  @impl true
  def __codec_info__ do
    %ExCodecs.Codec{
      name: :blosc2,
      category: :compression,
      module: __MODULE__,
      native?: true,
      streaming?: false,
      configurable?: true,
      version: blosc2_version()
    }
  end

  defp blosc2_version, do: "c-blosc2-chunk/pure-rust"

  @doc """
  Compresses a binary into a C-Blosc2-compatible **chunk**.

  ## Arguments

    * `data` (`binary()`) — uncompressed bytes. When shuffling, choose a
      `:typesize` matching each logical value; a whole-value multiple is
      preferred.
    * `opts` (`keyword()`) — compression settings:
      * `:cname` — `:blosclz | :lz4 | :lz4hc | :zstd | :zlib`; defaults to
        `:lz4`
      * `:clevel` — integer compression level in `0..9`; defaults to `5`
      * `:shuffle` — `:none | :byte | :bit`; defaults to `:byte`
      * `:typesize` — logical element size in bytes, integer `1..255`;
        defaults to `8`

      Unknown keys are ignored. `:snappy` is not a valid `:cname`.

  ## Returns

    * `{:ok, chunk :: binary()}` containing one Blosc2 chunk
    * `{:error, %ExCodecs.Error{reason: :invalid_data}}` when `data` is not a
      binary, `opts` is not a list, or the NIF raises an argument error
    * `{:error, %ExCodecs.Error{reason: :invalid_options}}` for an unsupported
      `:cname` (including `:snappy`) or an out-of-range option
    * `{:error, %ExCodecs.Error{reason: :compression_failed}}` when the native
      compressor fails
    * `{:error, %ExCodecs.Error{reason: :nif_not_loaded}}` when the native
      library is unavailable

  ## Raises / Exceptions

  Guard/option validation failures and `ErlangError`/`ArgumentError`
  exceptions from the NIF call are converted to error tuples. Unexpected
  exception classes may propagate.

  ## Examples

      iex> samples = <<100::little-16, 101::little-16, 102::little-16>>
      iex> {:ok, chunk} =
      ...>   ExCodecs.Compression.Blosc2.encode(samples,
      ...>     cname: :zstd,
      ...>     clevel: 7,
      ...>     shuffle: :byte,
      ...>     typesize: 2
      ...>   )
      iex> ExCodecs.Compression.Blosc2.decode(chunk, [])
      {:ok, <<100::little-16, 101::little-16, 102::little-16>>}

      iex> {:error, error} =
      ...>   ExCodecs.Compression.Blosc2.encode("data", cname: :snappy)
      iex> error.reason
      :invalid_options
  """
  @impl true
  def encode(data, opts) when is_binary(data) and is_list(opts) do
    with {:ok, {cname, clevel, shuffle, typesize}} <- BloscOptions.parse(opts, :blosc2) do
      ExCodecs.NIF.safe_call(:blosc2, fn ->
        ExCodecs.Native.blosc2_compress(data, cname, clevel, shuffle, typesize)
      end)
    end
  end

  def encode(_data, _opts) do
    {:error, ExCodecs.Error.new(:invalid_data, codec: :blosc2)}
  end

  @doc """
  Decompresses a Blosc2 **chunk** binary.

  ## Arguments

    * `data` (`binary()`) — one chunk produced by this codec or by
      C/python-blosc2 single-buffer `compress`
    * `opts` (`keyword()`) — optional `:max_output_size` (positive integer
      bytes, default 256 MiB)

  ## Returns

    * `{:ok, decompressed :: binary()}` on success
    * `{:error, %ExCodecs.Error{reason: :invalid_data}}` when `data` is not a
      binary, `opts` is not a list, the chunk header is shorter than 16 bytes,
      or the NIF raises an argument error
    * `{:error, %ExCodecs.Error{reason: :invalid_options}}` when
      `:max_output_size` is not a positive integer
    * `{:error, %ExCodecs.Error{reason: :output_limit_exceeded}}` when the
      declared chunk nbytes exceeds `:max_output_size` or the 1 GiB hard cap
    * `{:error, %ExCodecs.Error{reason: :decompression_failed}}` when the chunk
      is corrupt, truncated, unsupported, or is a Blosc2 container rather than
      a single chunk
    * `{:error, %ExCodecs.Error{reason: :nif_not_loaded}}` when the native
      library is unavailable

  ## Raises / Exceptions

  Guard failures and `ErlangError`/`ArgumentError` exceptions from the NIF
  call are converted to error tuples. Unexpected exception classes may
  propagate.

  ## Examples

      iex> payload = "one Blosc2 chunk"
      iex> {:ok, chunk} =
      ...>   ExCodecs.Compression.Blosc2.encode(payload, shuffle: :none, typesize: 1)
      iex> ExCodecs.Compression.Blosc2.decode(chunk, [])
      {:ok, "one Blosc2 chunk"}

      iex> {:error, error} = ExCodecs.Compression.Blosc2.decode("short", [])
      iex> error.reason
      :invalid_data
  """
  @impl true
  def decode(data, opts) when is_binary(data) and is_list(opts) do
    with {:ok, max} <- ExCodecs.NIF.max_output_size(opts) do
      ExCodecs.NIF.safe_call(:blosc2, fn -> ExCodecs.Native.blosc2_decompress(data, max) end)
    end
  end

  def decode(_data, _opts) do
    {:error, ExCodecs.Error.new(:invalid_data, codec: :blosc2)}
  end
end
