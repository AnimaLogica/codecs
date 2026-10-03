defmodule ExCodecs.NIF do
  @moduledoc """
  Shared NIF result wrapping and the library-wide decompress size ceiling.

  Compression codecs call `safe_call/2` around `ExCodecs.Native` functions so
  callers always see `{:ok, binary()}` or `{:error, %ExCodecs.Error{}}`, never
  raw `:erlang.nif_error/1` exceptions on the public API.

  ## Safety policy

  Decompression defaults to a **256 MiB** output ceiling (`default_max_output_size/0`).
  Override per call with `max_output_size:` (bytes). Exceeding the limit returns
  `:output_limit_exceeded`.

  ## Panic classification

  `safe_call/2` maps `:nif_not_loaded` precisely. Panic-like `ErlangError`
  payloads are logged at warning and returned as `:compression_failed` with
  message `"Native codec crashed"`.
  """

  @default_max_output_size 268_435_456

  @doc "Default decompress ceiling in bytes (256 MiB)."
  @spec default_max_output_size() :: pos_integer()
  def default_max_output_size, do: @default_max_output_size

  @doc """
  Reads `:max_output_size` from `opts`, defaulting to `default_max_output_size/0`.
  """
  @spec max_output_size(keyword()) :: {:ok, pos_integer()} | {:error, ExCodecs.Error.t()}
  def max_output_size(opts) when is_list(opts) do
    case Keyword.get(opts, :max_output_size, @default_max_output_size) do
      n when is_integer(n) and n > 0 ->
        {:ok, n}

      _ ->
        {:error,
         ExCodecs.Error.new(:invalid_options,
           message: "max_output_size must be a positive integer (bytes)"
         )}
    end
  end

  @doc """
  Wraps raw NIF `{:ok, binary}` / `{:error, atom}` results into `ExCodecs.Error`.
  """
  @spec wrap(atom(), {:ok, binary()} | {:error, atom()} | term()) ::
          {:ok, binary()} | {:error, ExCodecs.Error.t()}
  def wrap(_codec, {:ok, data}) when is_binary(data), do: {:ok, data}

  def wrap(codec, {:error, :compression_failed}),
    do: {:error, ExCodecs.Error.new(:compression_failed, codec: codec)}

  def wrap(codec, {:error, :decompression_failed}),
    do: {:error, ExCodecs.Error.new(:decompression_failed, codec: codec)}

  def wrap(codec, {:error, :output_limit_exceeded}),
    do:
      {:error,
       ExCodecs.Error.new(:output_limit_exceeded,
         codec: codec,
         message:
           "Decompressed output exceeded max_output_size. " <>
             "Pass a larger max_output_size: for trusted inputs."
       )}

  def wrap(codec, {:error, :invalid_data}),
    do: {:error, ExCodecs.Error.new(:invalid_data, codec: codec)}

  def wrap(codec, {:error, :invalid_options}),
    do: {:error, ExCodecs.Error.new(:invalid_options, codec: codec)}

  def wrap(codec, {:error, :truncated_input}),
    do: {:error, ExCodecs.Error.new(:truncated_input, codec: codec)}

  def wrap(codec, {:error, :checksum_mismatch}),
    do: {:error, ExCodecs.Error.new(:checksum_mismatch, codec: codec)}

  def wrap(codec, {:error, reason})
      when is_atom(reason) and
             reason not in [
               :compression_failed,
               :decompression_failed,
               :output_limit_exceeded,
               :invalid_data,
               :invalid_options,
               :nif_not_loaded,
               :io_error,
               :truncated_input,
               :checksum_mismatch
             ] do
    {:error,
     ExCodecs.Error.new(:invalid_data,
       codec: codec,
       message: "Unexpected NIF error atom: #{inspect(reason)}",
       details: reason
     )}
  end

  def wrap(codec, other) do
    {:error,
     ExCodecs.Error.new(:invalid_data,
       codec: codec,
       message: "Unexpected NIF return: #{inspect(other)}"
     )}
  end

  @doc """
  Invokes a zero-arity NIF function and wraps ErlangError/`nif_not_loaded`.
  """
  @spec safe_call(atom(), (-> term())) :: {:ok, binary()} | {:error, ExCodecs.Error.t()}
  def safe_call(codec, fun) when is_function(fun, 0) do
    wrap(codec, fun.())
  rescue
    e in ErlangError ->
      case e.original do
        :nif_not_loaded ->
          {:error, ExCodecs.Error.new(:nif_not_loaded, codec: codec)}

        other ->
          if nif_panic?(other) do
            require Logger

            Logger.warning("ExCodecs NIF panic in #{inspect(codec)}: #{inspect(other, limit: 32)}")

            {:error,
             ExCodecs.Error.new(:compression_failed,
               codec: codec,
               message: "Native codec crashed",
               details: other
             )}
          else
            {:error, ExCodecs.Error.new(:invalid_data, codec: codec, details: other)}
          end
      end

    e in ArgumentError ->
      {:error, ExCodecs.Error.new(:invalid_data, codec: codec, message: Exception.message(e))}
  end

  defp nif_panic?(other) when is_binary(other), do: true
  defp nif_panic?({:error, _}), do: true
  defp nif_panic?(other) when is_tuple(other), do: true
  defp nif_panic?(_), do: false
end
