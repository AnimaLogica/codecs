defmodule ExCodecs.Compression.Blosc do
  @moduledoc """
  Blosc **chunk** codec in the Blosc1 wire format (c-blosc 1.x), pure Rust.

  This is the format written by c-blosc 1.x, numcodecs `Blosc`, and the Zarr
  v2 and v3 `blosc` codecs. Use it when the bytes must be readable by those
  tools. `:blosc2` writes the newer Blosc2 chunk format, which c-blosc 1.x
  cannot read.

  ```
  binary  →  [shuffle | bitshuffle]  →  [compressor]  →  one Blosc1 chunk
  ```

  ## Options

    * `:cname` — `:blosclz` | `:lz4` (default) | `:lz4hc` | `:zstd` | `:zlib`
    * `:clevel` — `0..9` (default `5`); `0` stores the data uncompressed
    * `:shuffle` — `:none` | `:byte` (default) | `:bit`
    * `:typesize` — `1..255` (default `8`)
    * `:max_output_size` — decode only; maximum decompressed size in bytes
      (default: 256 MiB; also hard-capped at 1 GiB per chunk)

  ## Compatibility notes

    * `:lz4hc` produces standard LZ4 blocks (the encoder has no HC mode), so
      the ratio matches `:lz4`. Readers see an ordinary LZ4 chunk.
    * Blocks are never split into per-byte streams. Readers need c-blosc
      1.14 or newer, which honours the "not split" flag.
    * Bitshuffle is applied to blocks holding a multiple of 8 elements; other
      blocks are stored unfiltered, as c-blosc 1.x does.
    * `:snappy` is rejected: numcodecs and most c-blosc builds omit it.
    * Decoding also accepts Blosc2 chunks.

  ## Examples

      iex> {:ok, chunk} = ExCodecs.encode(:blosc, :binary.copy(<<1, 2, 3, 4>>, 64))
      iex> binary_part(chunk, 0, 1)
      <<2>>
      iex> ExCodecs.decode(:blosc, chunk)
      {:ok, :binary.copy(<<1, 2, 3, 4>>, 64)}
  """

  @behaviour ExCodecs.Codec

  alias ExCodecs.Compression.BloscOptions

  @doc """
  Returns the registry metadata for the Blosc1 chunk codec.

  ## Arguments

  This function takes no arguments.

  ## Returns

  An `ExCodecs.Codec.t()` with `name: :blosc`, `category: :compression`,
  `native?: true`, `streaming?: false`, `configurable?: true`, and
  `version: "blosc1-chunk/pure-rust"`.

  ## Raises / Exceptions

  This function does not invoke the NIF and does not raise.

  ## Examples

      iex> info = ExCodecs.Compression.Blosc.__codec_info__()
      iex> {info.name, info.category, info.version}
      {:blosc, :compression, "blosc1-chunk/pure-rust"}
  """
  @impl true
  def __codec_info__ do
    %ExCodecs.Codec{
      name: :blosc,
      category: :compression,
      module: __MODULE__,
      native?: true,
      streaming?: false,
      configurable?: true,
      version: "blosc1-chunk/pure-rust"
    }
  end

  @doc """
  Compresses a binary into one Blosc1 chunk.

  ## Arguments

    * `data` (`binary()`) — uncompressed bytes. With shuffling, set
      `:typesize` to the size of one element.
    * `opts` (`keyword()`) — `:cname`, `:clevel`, `:shuffle`, `:typesize`
      as described in the module docs. Unknown keys are ignored.

  ## Returns

    * `{:ok, chunk :: binary()}` containing one Blosc1 chunk
    * `{:error, %ExCodecs.Error{reason: :invalid_data}}` when `data` is not a
      binary or `opts` is not a list
    * `{:error, %ExCodecs.Error{reason: :invalid_options}}` for an unsupported
      `:cname` (including `:snappy`) or an out-of-range option
    * `{:error, %ExCodecs.Error{reason: :nif_not_loaded}}` when the native
      library is unavailable

  ## Raises / Exceptions

  Option validation failures and `ErlangError`/`ArgumentError` exceptions
  from the NIF call are converted to error tuples.

  ## Examples

      iex> samples = for i <- 1..256, into: <<>>, do: <<i::little-32>>
      iex> {:ok, chunk} =
      ...>   ExCodecs.Compression.Blosc.encode(samples, cname: :zstd, shuffle: :bit, typesize: 4)
      iex> ExCodecs.Compression.Blosc.decode(chunk, [])
      {:ok, samples}

      iex> {:error, error} = ExCodecs.Compression.Blosc.encode("data", cname: :snappy)
      iex> error.reason
      :invalid_options
  """
  @impl true
  def encode(data, opts) when is_binary(data) and is_list(opts) do
    with {:ok, {cname, clevel, shuffle, typesize}} <- BloscOptions.parse(opts, :blosc) do
      ExCodecs.NIF.safe_call(:blosc, fn ->
        ExCodecs.Native.blosc1_compress(data, cname, clevel, shuffle, typesize)
      end)
    end
  end

  def encode(_data, _opts), do: {:error, ExCodecs.Error.new(:invalid_data, codec: :blosc)}

  @doc """
  Decompresses one Blosc chunk (Blosc1, or Blosc2).

  ## Arguments

    * `data` (`binary()`) — one chunk from this codec, c-blosc, numcodecs, or
      a Zarr `blosc` codec
    * `opts` (`keyword()`) — optional `:max_output_size` (positive integer
      bytes, default 256 MiB)

  ## Returns

    * `{:ok, decompressed :: binary()}` on success
    * `{:error, %ExCodecs.Error{reason: :invalid_data}}` when `data` is not a
      binary, `opts` is not a list, or the chunk header is shorter than 16
      bytes
    * `{:error, %ExCodecs.Error{reason: :invalid_options}}` when
      `:max_output_size` is not a positive integer
    * `{:error, %ExCodecs.Error{reason: :output_limit_exceeded}}` when the
      declared size exceeds `:max_output_size` or the 1 GiB hard cap
    * `{:error, %ExCodecs.Error{reason: :decompression_failed}}` when the chunk
      is corrupt, truncated or unsupported
    * `{:error, %ExCodecs.Error{reason: :nif_not_loaded}}` when the native
      library is unavailable

  ## Raises / Exceptions

  Guard failures and `ErlangError`/`ArgumentError` exceptions from the NIF
  call are converted to error tuples.

  ## Examples

      iex> {:ok, chunk} = ExCodecs.Compression.Blosc.encode("short payload", [])
      iex> ExCodecs.Compression.Blosc.decode(chunk, [])
      {:ok, "short payload"}

      iex> {:error, error} = ExCodecs.Compression.Blosc.decode("short", [])
      iex> error.reason
      :invalid_data
  """
  @impl true
  def decode(data, opts) when is_binary(data) and is_list(opts) do
    with {:ok, max} <- ExCodecs.NIF.max_output_size(opts) do
      # The Blosc2 decoder reads Blosc1 chunks too.
      ExCodecs.NIF.safe_call(:blosc, fn -> ExCodecs.Native.blosc2_decompress(data, max) end)
    end
  end

  def decode(_data, _opts), do: {:error, ExCodecs.Error.new(:invalid_data, codec: :blosc)}
end
