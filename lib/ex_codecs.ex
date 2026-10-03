defmodule ExCodecs do
  @moduledoc """
  Extensible BEAM-native **codec framework** for Elixir.

  ## One framework, specialized category APIs

  Binary→binary registry codecs use:

      ExCodecs.encode(codec_atom, binary, opts \\\\ [])
      ExCodecs.decode(codec_atom, binary, opts \\\\ [])

  All implementations are registered in the shared `ExCodecs.CodecRegistry`
  catalog. Category modules provide entry points suited to their data:

    * `ExCodecs.Compression` — `compress/3` / `decompress/3` aliases of the
      registry API, plus listing codecs in the compression category
    * `ExCodecs.Spatial` — domain types and formats for point clouds /
      Gaussians (struct↔format). Call `ExCodecs.Spatial.encode/2` and
      `ExCodecs.Spatial.decode/2`

  The APIs belong to one framework and share tagged results and
  `%ExCodecs.Error{}` conventions. They are not overloaded because their input
  shapes differ. Registry encoding and decoding keep the codec atom first:

      {:ok, compressed} = ExCodecs.encode(:zstd, data)
      {:ok, decoded} = ExCodecs.decode(:zstd, compressed)

  ## Registry codecs

  | Codec | Notes |
  |-------|--------|
  | `:zstd` | Pure-Rust Zstd (`structured-zstd`) |
  | `:lz4` | Size-prepended `lz4_flex` blocks |
  | `:snappy` | Standalone Snappy codec |
  | `:bzip2` | Pure-Rust bzip2 |
  | `:blosc` | **Blosc1 chunk**: the c-blosc 1.x / numcodecs / Zarr `blosc` format |
  | `:blosc2` | **C-Blosc2 chunk** (not super-chunk / B2ND / `.b2frame`) |
  | `:crc32c` | Appends / verifies a little-endian CRC32C (Zarr v3 `crc32c`) |

  ### Snappy vs Blosc2 `cname: :snappy`

  - `ExCodecs.encode(:snappy, data)` — **supported** (standalone codec).
  - `ExCodecs.encode(:blosc2, data, cname: :snappy)` — **rejected** (`:invalid_options`).
    Snappy is not a standard C-Blosc2 inner compressor in this build; use
    `:lz4`, `:blosclz`, `:zstd`, `:lz4hc`, or `:zlib` inside Blosc2.

  ### Blosc vs Blosc2

  `:blosc` writes Blosc1 chunks, which c-blosc 1.x, numcodecs and zarr-python
  read. `:blosc2` writes the newer Blosc2 chunk format, which c-blosc 1.x
  rejects. Both decode either format. Use `:blosc` for Zarr data.

  ### Blosc2 “chunk only”

  `:blosc2` compresses **one buffer → one Blosc2 chunk**. That matches normal
  ExCodecs use (and python-blosc2 `compress`/`decompress` on a single buffer).
  It does **not** open `.b2frame` files, append super-chunks, or slice B2ND
  arrays. For large data, chunk yourself and store multiple blobs.

  ## Quick start

      # Registry compression
      {:ok, c} = ExCodecs.encode(:zstd, "hello")
      {:ok, "hello"} = ExCodecs.decode(:zstd, c)

      # Category alias
      {:ok, c} = ExCodecs.Compression.compress(:lz4, data)

      # Spatial category
      alias ExCodecs.Spatial.{Point, PointCloud}
      cloud = PointCloud.new([Point.new(0.0, 0.0, 0.0)])
      {:ok, ply} = ExCodecs.Spatial.encode(cloud, format: :ply)
      {:ok, cloud} = ExCodecs.Spatial.decode(ply, format: :ply)

      ExCodecs.available_codecs()
      #=> [:blosc, :blosc2, :bzip2, :crc32c, :gsplat, :lz4, :ply, :snappy, :spatial_binary, :zstd]

  ## Error policy

  Public encode/decode paths return `{:ok, _}` or `{:error, %ExCodecs.Error{}}`.
  They do **not** raise for invalid codecs, bad options, or compression failure.
  (NIF load failure is converted to `{:error, %Error{reason: :nif_not_loaded}}`.)
  """

  alias ExCodecs.{Codec, CodecRegistry, Error}

  @doc """
  Encodes a **binary** with a **registered** codec.

  Primary framework entry point. First argument is always a codec atom
  (`:zstd`, `:lz4`, …). For spatial structs use `ExCodecs.Spatial.encode/2`.

  ## Arguments

    * `codec` (`atom()`) — registry key, such as `:zstd`
    * `data` (`binary()`) — unencoded bytes
    * `opts` (`keyword()`) — codec-specific options; defaults to `[]`

  ## Returns

    * `{:ok, binary()}` — encoded payload
    * `{:error, %ExCodecs.Error{reason: :unsupported_codec}}` — `codec` is not
      registered
    * `{:error, %ExCodecs.Error{reason: :codec_unavailable}}` — `codec` is
      registered without an implementation module
    * `{:error, %ExCodecs.Error{reason: :invalid_data}}` — `data` is not a
      binary, arguments do not have the documented shape, or the codec rejects
      the input
    * `{:error, %ExCodecs.Error{reason: :invalid_options}}` — codec-specific
      option validation failed
    * `{:error, %ExCodecs.Error{reason: :compression_failed}}` — native encoder
      failed
    * `{:error, %ExCodecs.Error{reason: :nif_not_loaded}}` — native library is
      unavailable

  ## Raises

  Does not raise for the documented failure modes, including malformed public
  arguments. It may raise `ArgumentError` if the registry has not been started,
  or propagate an unexpected exception from a third-party registered codec.

  ## Examples

      iex> {:ok, compressed} = ExCodecs.encode(:zstd, "hello world")
      iex> is_binary(compressed)
      true

      iex> {:ok, compressed} = ExCodecs.encode(:zstd, "hello world", level: 3)
      iex> is_binary(compressed)
      true

      iex> {:error, %ExCodecs.Error{reason: :unsupported_codec}} =
      ...>   ExCodecs.encode(:not_a_codec, "x")
      iex> true
      true
  """
  @spec encode(atom(), binary(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(codec, data, opts \\ [])

  def encode(codec, data, opts) when is_atom(codec) and is_binary(data) and is_list(opts) do
    case CodecRegistry.lookup(codec) do
      {:ok, {_module, _category, %{interface: interface}}}
      when interface != :binary ->
        interface_error(codec, :encode)

      {:ok, {module, _category, info}} ->
        case ensure_available(info, codec) do
          :ok -> module.encode(data, opts)
          {:error, %Error{} = error} -> {:error, error}
        end

      {:error, :unsupported_codec} ->
        {:error, Error.new(:unsupported_codec, codec: codec)}
    end
  end

  def encode(codec, _data, _opts) when is_atom(codec) do
    {:error,
     Error.new(:invalid_data,
       codec: codec,
       message: "ExCodecs.encode/3 expects a binary as the second argument"
     )}
  end

  def encode(%_{} = struct, _data_or_opts, _opts) do
    {:error,
     Error.new(:invalid_data,
       message:
         "Structured spatial data is encoded via ExCodecs.Spatial.encode/2 " <>
           "(got #{inspect(struct.__struct__)}). Registry encode/3 is binary codecs only."
     )}
  end

  def encode(_codec, _data, _opts) do
    {:error,
     Error.new(:invalid_data,
       message: "ExCodecs.encode/3 expects encode(codec_atom, binary, opts \\\\ [])"
     )}
  end

  @doc """
  Decodes a **binary** with a **registered** codec.

  First argument is always a codec atom. For spatial formats use
  `ExCodecs.Spatial.decode/2` with `format:`.

  ## Arguments

    * `codec` (`atom()`) — registry key, such as `:zstd`
    * `data` (`binary()`) — encoded payload
    * `opts` (`keyword()`) — codec-specific decoding options; defaults to `[]`

  ## Returns

    * `{:ok, binary()}` — decoded payload
    * `{:error, %ExCodecs.Error{reason: :unsupported_codec}}` — `codec` is not
      registered
    * `{:error, %ExCodecs.Error{reason: :codec_unavailable}}` — `codec` has no
      implementation module
    * `{:error, %ExCodecs.Error{reason: :invalid_data}}` — arguments have the
      wrong shape or the codec rejects the input
    * `{:error, %ExCodecs.Error{reason: :invalid_options}}` — options are
      invalid, including the mistaken `decode(binary, format: format)` shape
    * `{:error, %ExCodecs.Error{reason: :decompression_failed}}` — payload is
      corrupt or the native decoder failed
    * `{:error, %ExCodecs.Error{reason: :nif_not_loaded}}` — native library is
      unavailable

  ## Raises

  Does not raise for the documented failure modes. It may raise `ArgumentError`
  if the registry has not been started, or propagate an unexpected exception
  from a third-party registered codec.

  ## Examples

      iex> {:ok, compressed} = ExCodecs.encode(:zstd, "hello world")
      iex> {:ok, original} = ExCodecs.decode(:zstd, compressed)
      iex> original
      "hello world"
  """
  @spec decode(atom(), binary(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def decode(codec, data, opts \\ [])

  def decode(codec, data, opts) when is_atom(codec) and is_binary(data) and is_list(opts) do
    case CodecRegistry.lookup(codec) do
      {:ok, {_module, _category, %{interface: interface}}}
      when interface != :binary ->
        interface_error(codec, :decode)

      {:ok, {module, _category, info}} ->
        case ensure_available(info, codec) do
          :ok -> module.decode(data, opts)
          {:error, %Error{} = error} -> {:error, error}
        end

      {:error, :unsupported_codec} ->
        {:error, Error.new(:unsupported_codec, codec: codec)}
    end
  end

  def decode(codec, _data, _opts) when is_atom(codec) do
    {:error,
     Error.new(:invalid_data,
       codec: codec,
       message: "ExCodecs.decode/3 expects a binary as the second argument"
     )}
  end

  def decode(data, opts, []) when is_binary(data) and is_list(opts) do
    if Keyword.has_key?(opts, :format) do
      {:error,
       Error.new(:invalid_options,
         message:
           "Spatial formats use ExCodecs.Spatial.decode/2 " <>
             "(e.g. ExCodecs.Spatial.decode(data, format: :ply)). " <>
             "Registry decode/3 is decode(codec_atom, binary, opts)."
       )}
    else
      {:error,
       Error.new(:invalid_data,
         message: "ExCodecs.decode/3 expects decode(codec_atom, binary, opts \\\\ [])"
       )}
    end
  end

  def decode(_codec, _data, _opts) do
    {:error,
     Error.new(:invalid_data,
       message: "ExCodecs.decode/3 expects decode(codec_atom, binary, opts \\\\ [])"
     )}
  end

  @doc """
  Lazily enumerates **spatial** primitives from a file path or binary.

  Delegates to `ExCodecs.Spatial.stream_decode/2`. **Not** used for registry
  compression codecs. File sources stream record-by-record; in-memory binaries
  materialize through `decode/2` (or use chunked Rust unpack when the spatial
  NIF is loaded).

  ## Arguments

    * `source` (`Path.t() | binary()`) — filesystem path or encoded binary;
      use the `:source` option to disambiguate a binary that is also a path
    * `opts` (`keyword()`) — requires `:format` (`:ply`, `:spatial_binary`, or
      `:gsplat`); optionally accepts `:source` (`:auto`, `:file`, or `:binary`)
      and format-specific options

  ## Returns

  An `Enumerable.t()` yielding `%ExCodecs.Spatial.Point{}` or
  `%ExCodecs.Spatial.Gaussian{}` values. On failure it yields exactly one
  `{:error, %ExCodecs.Error{}}` element with one of these reasons:

    * `:invalid_options` — required `:format` is absent
    * `:unsupported_codec` — the format is not stream-decodable
    * `:io_error` — a file source cannot be read
    * `:invalid_data` — the encoded payload is malformed or truncated

  ## Raises

  Missing or invalid format values and file read errors are yielded as error
  tuples. Passing non-keyword `opts` raises `FunctionClauseError`; enumeration
  may propagate unexpected exceptions from the source enumerable or runtime.

  ## Examples

      iex> alias ExCodecs.Spatial.{Point, PointCloud}
      iex> {:ok, bin} = ExCodecs.Spatial.encode(PointCloud.new([Point.new(1.0, 2.0, 3.0)]), format: :ply)
      iex> [%Point{x: x} | _] = ExCodecs.stream_decode(bin, format: :ply) |> Enum.to_list()
      iex> x == 1.0
      true
  """
  @spec stream_decode(Path.t() | binary(), keyword()) :: Enumerable.t()
  def stream_decode(source, opts) when is_list(opts) do
    ExCodecs.Spatial.stream_decode(source, opts)
  end

  @doc """
  Encodes an enumerable of spatial `%Point{}` / `%Gaussian{}` values.

  Delegates to `ExCodecs.Spatial.stream_encode/2`. Collects the enumerable
  (format headers need a count). **Not** for registry compression codecs.

  ## Arguments

    * `enumerable` (`Enumerable.t()`) — points or Gaussians, all of one type
    * `opts` (`keyword()`) — requires `:format` (`:ply`, `:spatial_binary`, or
      `:gsplat`) and may contain format-specific options

  ## Returns

    * `{:ok, binary()}` — encoded spatial payload
    * `{:error, %ExCodecs.Error{reason: :invalid_options}}` — required format
      is absent or a format option is invalid
    * `{:error, %ExCodecs.Error{reason: :unsupported_codec}}` — format is
      unknown
    * `{:error, %ExCodecs.Error{reason: :invalid_data}}` — items are mixed,
      malformed, unsupported, or include an error tuple

  ## Raises

  Returns error tuples for documented format, option, and item failures.
  Passing non-keyword `opts` raises `FunctionClauseError`. A value that does not
  implement `Enumerable` raises `Protocol.UndefinedError`, and exceptions raised
  while enumerating propagate.

  ## Examples

      iex> alias ExCodecs.Spatial.Point
      iex> {:ok, bin} = ExCodecs.stream_encode([Point.new(0.0, 0.0, 0.0)], format: :ply)
      iex> is_binary(bin)
      true
  """
  @spec stream_encode(Enumerable.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def stream_encode(enumerable, opts) when is_list(opts) do
    ExCodecs.Spatial.stream_encode(enumerable, opts)
  end

  @doc """
  Lists **registered** codec atoms that are available at runtime.

  ## Arguments

  None.

  ## Returns

  A sorted `[atom()]` containing every shared-catalog entry whose
  implementation module is non-`nil`, including binary and spatial codecs.

  ## Raises

  May raise `ArgumentError` if the registry ETS table has not been started.

  ## Examples

      iex> :blosc2 in ExCodecs.available_codecs()
      true
  """
  @spec available_codecs() :: [atom()]
  def available_codecs do
    CodecRegistry.available_codecs()
  end

  @doc """
  Lists available codec names in one category.

  ## Arguments

    * `category` — category atom such as `:compression` or `:spatial`

  ## Returns

  A sorted list of available names in that category.

  ## Raises

  Raises `FunctionClauseError` for a non-atom category and may raise
  `ArgumentError` if the shared catalog has not started.

  ## Examples

      iex> ExCodecs.available_codecs(:spatial)
      [:gsplat, :ply, :spatial_binary]
  """
  @spec available_codecs(atom()) :: [atom()]
  def available_codecs(category) when is_atom(category) do
    CodecRegistry.available_codecs(category)
  end

  @doc """
  Returns whether a shared-catalog codec is available.

  ## Arguments

    * `codec` (`atom()`) — registry key to test

  ## Returns

  `true` if `codec` is registered with a non-`nil` implementation module;
  otherwise `false`.

  ## Raises

  Raises `FunctionClauseError` if `codec` is not an atom. May raise
  `ArgumentError` if the registry ETS table has not been started.

  ## Examples

      iex> ExCodecs.supports?(:zstd)
      true

      iex> ExCodecs.supports?(:nonexistent)
      false
  """
  @spec supports?(atom()) :: boolean()
  def supports?(codec) when is_atom(codec) do
    CodecRegistry.supports?(codec)
  end

  @doc """
  Returns metadata for a registered codec.

  ## Arguments

    * `codec` (`atom()`) — registry key whose metadata is requested

  ## Returns

    * `{:ok, ExCodecs.Codec.t()}` — name, category, interface, module,
      capability flags, and backend version; unavailable codecs are returned
      with `module: nil`
    * `{:error, :unsupported_codec}` — not registered (note: bare atom, not `%Error{}`)

  ## Raises

  Raises `FunctionClauseError` if `codec` is not an atom. May raise
  `ArgumentError` if the registry ETS table has not been started.

  ## Examples

      iex> {:ok, info} = ExCodecs.codec_info(:zstd)
      iex> info.name
      :zstd

      iex> {:ok, info} = ExCodecs.codec_info(:zstd)
      iex> info.category
      :compression
  """
  @spec codec_info(atom()) :: {:ok, Codec.t()} | {:error, :unsupported_codec}
  def codec_info(codec) when is_atom(codec) do
    CodecRegistry.codec_info(codec)
  end

  defp ensure_available(info, codec) do
    if info.module != nil do
      :ok
    else
      {:error, Error.new(:codec_unavailable, codec: codec)}
    end
  end

  defp interface_error(codec, operation) do
    {:error,
     Error.new(:invalid_options,
       codec: codec,
       message:
         "#{inspect(codec)} uses the spatial category API; call " <>
           "ExCodecs.Spatial.#{operation}/2 with format: #{inspect(codec)}"
     )}
  end
end
