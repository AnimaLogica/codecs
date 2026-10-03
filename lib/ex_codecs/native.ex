# coveralls-ignore-start
defmodule ExCodecs.Native do
  @moduledoc """
  Native NIF module providing Rust-based compression implementations.

  This module loads precompiled NIF binaries for Zstd, LZ4, Snappy, Bzip2,
  Blosc (Blosc1 chunks), Blosc2 and CRC32C via `RustlerPrecompiled`. If a precompiled
  artifact is not available for the current platform, it falls back to compiling
  the Rust NIF from source (requires the Rust toolchain).

  If the NIF fails to load entirely, all functions fall back to
  `:erlang.nif_error(:nif_not_loaded)`, and codecs are registered as unavailable
  at startup.

  > **Note**: This module is excluded from coverage because all functions are
  > Rustler NIF stubs that are replaced at load time by the native implementation.
  """

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :ex_codecs,
    crate: :ex_codecs_native,
    version: version,
    # This URL must match the GitHub repo that hosts release artifacts.
    # If the repo is renamed, published checksums become invalid until
    # a new release is cut. Keep in sync with @source_url in mix.exs.
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

  @doc false
  def zstd_compress(_data, _level), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def zstd_decompress(_data, _max_output_size), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def lz4_compress(_data), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def lz4_decompress(_data, _max_output_size), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def snappy_compress(_data), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def snappy_decompress(_data, _max_output_size), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def bzip2_compress(_data, _block_size), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def bzip2_decompress(_data, _max_output_size), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def blosc1_compress(_data, _cname, _clevel, _shuffle, _typesize),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def crc32c_checksum(_data), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def crc32c_encode(_data), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def crc32c_decode(_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def blosc2_compress(_data, _cname, _clevel, _shuffle, _typesize),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def blosc2_decompress(_data, _max_output_size), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def codec_versions, do: :erlang.nif_error(:nif_not_loaded)

  # --- Spatial acceleration (DirtyCpu) ---------------------------------------

  @doc false
  def excp_unpack(_data, _flags, _offset, _max_count), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def excp_pack(_records, _flags), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def gspl_unpack(_data, _sh_rest, _offset, _max_count), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def gspl_pack(_records, _sh_rest), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def ply_binary_unpack(_data, _types, _little_endian, _offset, _max_count),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def spatial_mmap_open(_path), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def spatial_mmap_len(_resource), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def excp_unpack_mmap(_resource, _flags, _offset, _max_count),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def gspl_unpack_mmap(_resource, _sh_rest, _offset, _max_count),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def ply_binary_unpack_mmap(_resource, _types, _little_endian, _offset, _max_count),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def spatial_append_file(_path, _data), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns `true` when the native NIF library is loaded.

  The check calls the native `codec_versions/0` function and verifies that it
  returns a map. This function is primarily useful for startup diagnostics;
  public compression calls already convert an unavailable NIF into
  `%ExCodecs.Error{reason: :nif_not_loaded}`.

  ## Arguments

  This function takes no arguments.

  ## Returns

    * `true` when the native library responds with its codec-version map.
    * `false` when the NIF stub raises `ErlangError` or `ArgumentError`.

  ## Raises

  Expected NIF-loading errors are caught. An exception of another class raised
  by the native implementation is not caught and propagates to the caller.

  ## Example

      iex> loaded? = ExCodecs.Native.nif_loaded?()
      iex> is_boolean(loaded?)
      true
  """
  @spec nif_loaded?() :: boolean()
  def nif_loaded? do
    is_map(codec_versions())
  rescue
    # ErlangError: NIF not loaded (stub raises nif_error).
    # ArgumentError: rare Rustler resource-arity mismatch on some OTPs.
    ErlangError -> false
    ArgumentError -> false
  end
end

# coveralls-ignore-stop
