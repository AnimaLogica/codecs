defmodule ExCodecs.Compression.BloscOptions do
  @moduledoc false
  # Option parsing shared by the Blosc1 (`:blosc`) and Blosc2 (`:blosc2`) chunk
  # codecs. Both NIFs take the same integer encodings.

  @default_cname :lz4
  @default_clevel 5
  @default_shuffle :byte
  @default_typesize 8

  @valid_cnames [:blosclz, :lz4, :lz4hc, :zstd, :zlib]
  @valid_shuffles [:none, :byte, :bit]

  @spec valid_cnames() :: [atom()]
  def valid_cnames, do: @valid_cnames

  @doc false
  @spec parse(keyword(), atom()) ::
          {:ok, {non_neg_integer(), 0..9, 0..2, 1..255}} | {:error, ExCodecs.Error.t()}
  def parse(opts, codec) do
    cname = Keyword.get(opts, :cname, @default_cname)
    clevel = Keyword.get(opts, :clevel, @default_clevel)
    shuffle = Keyword.get(opts, :shuffle, @default_shuffle)
    typesize = Keyword.get(opts, :typesize, @default_typesize)

    with :ok <- validate_cname(cname, codec),
         :ok <- validate_clevel(clevel, codec),
         :ok <- validate_shuffle(shuffle, codec),
         :ok <- validate_typesize(typesize, codec) do
      {:ok, {cname_to_int(cname), clevel, shuffle_to_int(shuffle), typesize}}
    end
  end

  defp validate_cname(cname, _codec) when cname in @valid_cnames, do: :ok

  defp validate_cname(:snappy, codec) do
    invalid(
      codec,
      ":snappy is not supported inside Blosc chunks; use one of: #{inspect(@valid_cnames)}"
    )
  end

  defp validate_cname(_, codec),
    do: invalid(codec, "cname must be one of: #{inspect(@valid_cnames)}")

  defp validate_clevel(level, _codec) when is_integer(level) and level >= 0 and level <= 9, do: :ok
  defp validate_clevel(_, codec), do: invalid(codec, "clevel must be an integer between 0 and 9")

  defp validate_shuffle(shuffle, _codec) when shuffle in @valid_shuffles, do: :ok

  defp validate_shuffle(_, codec),
    do: invalid(codec, "shuffle must be one of: #{inspect(@valid_shuffles)}")

  defp validate_typesize(ts, _codec) when is_integer(ts) and ts > 0 and ts <= 255, do: :ok
  defp validate_typesize(_, codec), do: invalid(codec, "typesize must be an integer from 1 to 255")

  defp invalid(codec, message),
    do: {:error, ExCodecs.Error.new(:invalid_options, codec: codec, message: message)}

  defp cname_to_int(:blosclz), do: 0
  defp cname_to_int(:lz4), do: 1
  defp cname_to_int(:lz4hc), do: 2
  defp cname_to_int(:zlib), do: 4
  defp cname_to_int(:zstd), do: 5

  defp shuffle_to_int(:none), do: 0
  defp shuffle_to_int(:byte), do: 1
  defp shuffle_to_int(:bit), do: 2
end
