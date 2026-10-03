defmodule ExCodecs.Checksum.Crc32c do
  @moduledoc """
  CRC32C (Castagnoli) checksum codec.

  `encode/2` appends the little-endian CRC32C of the data; `decode/2` checks it
  and strips it. This is the Zarr v3 `crc32c` codec, also used to protect
  `sharding_indexed` shard indexes.

  ## Examples

      iex> {:ok, framed} = ExCodecs.encode(:crc32c, "123456789")
      iex> binary_part(framed, 9, 4)
      <<0x83, 0x92, 0x06, 0xE3>>
      iex> ExCodecs.decode(:crc32c, framed)
      {:ok, "123456789"}
  """

  @behaviour ExCodecs.Codec

  @doc """
  Returns the registry metadata for the CRC32C codec.

  ## Arguments

  This function takes no arguments.

  ## Returns

  An `ExCodecs.Codec.t()` with `name: :crc32c`, `category: :checksum`,
  `native?: true`, `streaming?: false`, and `configurable?: false`.

  ## Raises / Exceptions

  This function does not invoke the NIF and does not raise.

  ## Examples

      iex> info = ExCodecs.Checksum.Crc32c.__codec_info__()
      iex> {info.name, info.category}
      {:crc32c, :checksum}
  """
  @impl true
  def __codec_info__ do
    %ExCodecs.Codec{
      name: :crc32c,
      category: :checksum,
      module: __MODULE__,
      native?: true,
      streaming?: false,
      configurable?: false,
      version: "crc32c"
    }
  end

  @doc """
  Computes the CRC32C of a binary.

  ## Arguments

    * `data` (`binary()`) — bytes to checksum

  ## Returns

    * `{:ok, checksum :: non_neg_integer()}`
    * `{:error, %ExCodecs.Error{reason: :invalid_data}}` when `data` is not a
      binary
    * `{:error, %ExCodecs.Error{reason: :nif_not_loaded}}` when the native
      library is unavailable

  ## Raises / Exceptions

  NIF load errors are converted to error tuples.

  ## Examples

      iex> ExCodecs.Checksum.Crc32c.checksum("123456789")
      {:ok, 0xE3069283}
  """
  @spec checksum(binary()) :: {:ok, non_neg_integer()} | {:error, ExCodecs.Error.t()}
  def checksum(data) when is_binary(data) do
    {:ok, ExCodecs.Native.crc32c_checksum(data)}
  rescue
    e in ErlangError -> {:error, ExCodecs.Error.new(:nif_not_loaded, codec: :crc32c, details: e)}
  end

  def checksum(_data), do: {:error, ExCodecs.Error.new(:invalid_data, codec: :crc32c)}

  @doc """
  Appends the little-endian CRC32C of `data`.

  ## Arguments

    * `data` (`binary()`) — bytes to protect
    * `opts` (`keyword()`) — ignored; accepted for the codec interface

  ## Returns

    * `{:ok, data <> <<crc::little-32>>}`
    * `{:error, %ExCodecs.Error{reason: :invalid_data}}` when `data` is not a
      binary or `opts` is not a list
    * `{:error, %ExCodecs.Error{reason: :nif_not_loaded}}` when the native
      library is unavailable

  ## Raises / Exceptions

  `ErlangError`/`ArgumentError` exceptions from the NIF call are converted to
  error tuples.

  ## Examples

      iex> ExCodecs.Checksum.Crc32c.encode("", [])
      {:ok, <<0, 0, 0, 0>>}
  """
  @impl true
  def encode(data, opts) when is_binary(data) and is_list(opts) do
    ExCodecs.NIF.safe_call(:crc32c, fn -> ExCodecs.Native.crc32c_encode(data) end)
  end

  def encode(_data, _opts), do: {:error, ExCodecs.Error.new(:invalid_data, codec: :crc32c)}

  @doc """
  Verifies and strips a trailing little-endian CRC32C.

  ## Arguments

    * `data` (`binary()`) — payload followed by its 4-byte CRC32C
    * `opts` (`keyword()`) — ignored; accepted for the codec interface

  ## Returns

    * `{:ok, payload :: binary()}` when the checksum matches
    * `{:error, %ExCodecs.Error{reason: :checksum_mismatch}}` when it does not
    * `{:error, %ExCodecs.Error{reason: :truncated_input}}` when `data` is
      shorter than 4 bytes
    * `{:error, %ExCodecs.Error{reason: :invalid_data}}` when `data` is not a
      binary or `opts` is not a list
    * `{:error, %ExCodecs.Error{reason: :nif_not_loaded}}` when the native
      library is unavailable

  ## Raises / Exceptions

  `ErlangError`/`ArgumentError` exceptions from the NIF call are converted to
  error tuples.

  ## Examples

      iex> {:ok, framed} = ExCodecs.Checksum.Crc32c.encode("payload", [])
      iex> ExCodecs.Checksum.Crc32c.decode(framed, [])
      {:ok, "payload"}

      iex> {:error, error} = ExCodecs.Checksum.Crc32c.decode("payload" <> <<0, 0, 0, 0>>, [])
      iex> error.reason
      :checksum_mismatch
  """
  @impl true
  def decode(data, opts) when is_binary(data) and is_list(opts) do
    ExCodecs.NIF.safe_call(:crc32c, fn -> ExCodecs.Native.crc32c_decode(data) end)
  end

  def decode(_data, _opts), do: {:error, ExCodecs.Error.new(:invalid_data, codec: :crc32c)}
end
