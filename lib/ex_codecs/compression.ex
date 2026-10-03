defmodule ExCodecs.Compression do
  @moduledoc """
  Compression **category module**.

  Thin category helper: domain names (`compress` / `decompress`) and listing.
  The real API is still `ExCodecs.encode/3` / `decode/3` (codec atom + binary).

  ## Available codec modules

    * `ExCodecs.Compression.Zstd`
    * `ExCodecs.Compression.Lz4`
    * `ExCodecs.Compression.Snappy` — standalone Snappy (not Blosc2 `cname: :snappy`)
    * `ExCodecs.Compression.Bzip2`
    * `ExCodecs.Compression.Blosc` — Blosc1 **chunk** (c-blosc 1.x, numcodecs, Zarr)
    * `ExCodecs.Compression.Blosc2` — C-Blosc2 **chunk** only

  ## Examples

      {:ok, c} = ExCodecs.Compression.compress(:zstd, data, level: 3)
      {:ok, d} = ExCodecs.Compression.decompress(:zstd, c)
      # same as:
      {:ok, c} = ExCodecs.encode(:zstd, data, level: 3)
  """

  alias ExCodecs.CodecRegistry

  @doc """
  Lists metadata for every registered compression codec.

  ## Arguments

  This function takes no arguments.

  ## Returns

  A list of `ExCodecs.Codec.t()` values sorted by codec name. Each struct
  describes the registry name, implementation module, native/configuration
  flags, streaming support, and backend version. A known codec that is not
  available at runtime may have `module: nil`.

  ## Raises / Exceptions

  This function does not raise.

  ## Examples

      iex> codecs = ExCodecs.Compression.available_codecs()
      iex> Enum.map(codecs, & &1.name)
      [:blosc, :blosc2, :bzip2, :lz4, :snappy, :zstd]
      iex> Enum.all?(codecs, &(&1.category == :compression))
      true
  """
  @spec available_codecs() :: [ExCodecs.Codec.t()]
  def available_codecs do
    CodecRegistry.codecs_by_category(:compression)
  end

  @doc """
  Compresses `data` with a registered compression codec.

  This is the compression-category alias for `ExCodecs.encode/3`.

  ## Arguments

    * `codec` (`atom()`) — registered compression codec, such as `:zstd`,
      `:lz4`, `:snappy`, `:bzip2`, or `:blosc2`
    * `data` (`binary()`) — bytes to compress
    * `opts` (`keyword()`) — codec-specific options; defaults to `[]`

  ## Returns

    * `{:ok, compressed :: binary()}` on success
    * `{:error, %ExCodecs.Error{reason: reason}}` on failure, where `reason`
      can be:
      * `:unsupported_codec` when `codec` is not registered
      * `:codec_unavailable` when its implementation is unavailable
      * `:invalid_data` when the arguments have the wrong shape
      * `:invalid_options` when codec option validation fails
      * `:compression_failed` when the native compressor rejects the operation
      * `:nif_not_loaded` when the native library is unavailable

  ## Raises / Exceptions

  Normal validation and wrapped NIF failures are returned as error tuples.
  Unexpected VM-level faults outside the NIF wrapper may still raise.

  ## Examples

      iex> payload = "sensor=18.4"
      iex> {:ok, compressed} = ExCodecs.Compression.compress(:zstd, payload, level: 3)
      iex> {:ok, ^payload} = ExCodecs.Compression.decompress(:zstd, compressed)

      iex> {:error, error} = ExCodecs.Compression.compress(:zstd, "data", level: 23)
      iex> error.reason
      :invalid_options
  """
  @spec compress(atom(), binary(), keyword()) :: {:ok, binary()} | {:error, ExCodecs.Error.t()}
  def compress(codec, data, opts \\ []) do
    ExCodecs.encode(codec, data, opts)
  end

  @doc """
  Decompresses `data` with a registered compression codec.

  This is the compression-category alias for `ExCodecs.decode/3`.

  ## Arguments

    * `codec` (`atom()`) — registered codec that produced the payload
    * `data` (`binary()`) — compressed bytes in that codec's wire format
    * `opts` (`keyword()`) — decode options; defaults to `[]`. Built-in
      compression codecs honor `:max_output_size` (positive integer bytes,
      default 256 MiB). Do not raise the limit for untrusted inputs.
      lz4/snappy/blosc2 allocate up to `max_output_size` before verifying
      content, so N concurrent malicious requests can occupy N x 256 MiB;
      tighten the limit for concurrent untrusted workloads.

  ## Returns

    * `{:ok, decompressed :: binary()}` on success
    * `{:error, %ExCodecs.Error{reason: reason}}` on failure, where `reason`
      can be:
      * `:unsupported_codec` when `codec` is not registered
      * `:codec_unavailable` when its implementation is unavailable
      * `:invalid_data` for invalid argument types or an unexpected NIF result
      * `:invalid_options` when `:max_output_size` is not a positive integer
      * `:output_limit_exceeded` when decompressed size would exceed the limit
      * `:decompression_failed` for corrupt, truncated, or mismatched input
      * `:nif_not_loaded` when the native library is unavailable

  ## Raises / Exceptions

  Normal validation and wrapped NIF failures are returned as error tuples.
  Unexpected VM-level faults outside the NIF wrapper may still raise.

  ## Examples

      iex> payload = <<0, 1, 2, 3, 4>>
      iex> {:ok, compressed} = ExCodecs.Compression.compress(:snappy, payload)
      iex> ExCodecs.Compression.decompress(:snappy, compressed)
      {:ok, <<0, 1, 2, 3, 4>>}

      iex> {:error, error} = ExCodecs.Compression.decompress(:snappy, "not snappy")
      iex> error.reason
      :decompression_failed
  """
  @spec decompress(atom(), binary(), keyword()) :: {:ok, binary()} | {:error, ExCodecs.Error.t()}
  def decompress(codec, data, opts \\ []) do
    ExCodecs.decode(codec, data, opts)
  end
end
