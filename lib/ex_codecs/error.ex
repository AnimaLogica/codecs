defmodule ExCodecs.Error do
  @moduledoc """
  Structured errors for ExCodecs public APIs.

  Successful operations return `{:ok, result}`. Failures return
  `{:error, %ExCodecs.Error{}}` (except `codec_info/1`, which uses
  `{:error, :unsupported_codec}` for historical reasons).

  `%ExCodecs.Error{}` is both the structured error value returned in tagged
  tuples and an exception that can be raised explicitly. Its fields are:

    * `reason` (`error_reason()`) — stable, machine-readable reason
    * `message` (`String.t()`) — human-readable exception message
    * `codec` (`atom() | nil`) — related codec or format, when known
    * `details` (`term() | nil`) — optional backend or I/O diagnostic data

  For example:

      iex> error = ExCodecs.Error.new(:invalid_options, codec: :zstd, details: [level: 99])
      iex> {error.reason, error.codec, error.details}
      {:invalid_options, :zstd, [level: 99]}

  | Reason | Meaning |
  |--------|---------|
  | `:unsupported_codec` | Codec/format atom unknown |
  | `:codec_unavailable` | Known but NIF/module not loadable |
  | `:invalid_data` | Wrong type or corrupt payload |
  | `:invalid_options` | Bad keyword options |
  | `:compression_failed` | Native compress failed |
  | `:decompression_failed` | Native decompress failed |
  | `:nif_not_loaded` | NIF library missing |
  | `:io_error` | File read/write failure |
  | `:truncated_input` | Incomplete binary |
  | `:output_limit_exceeded` | Decompress would exceed `max_output_size` |
  | `:checksum_mismatch` | Stored checksum does not match the data |

  ## As exception

  `defexception` is defined so `raise error` works, but library code prefers
  tagged tuples. `Exception.message/1` returns the `message` field.
  """

  @typedoc """
  Stable reason atom carried by `t:ExCodecs.Error.t/0`.

    * `:unsupported_codec` — codec or format is not known
    * `:codec_unavailable` — codec is known but its module or NIF is unavailable
    * `:invalid_data` — input has the wrong type, shape, or semantic content
    * `:invalid_options` — an option name or value is invalid
    * `:compression_failed` — encoding backend failed
    * `:decompression_failed` — decoding backend failed or rejected corruption
    * `:nif_not_loaded` — native library could not be loaded
    * `:io_error` — file operation failed
    * `:truncated_input` — encoded input ended before a complete value
    * `:output_limit_exceeded` — decompress output would exceed `max_output_size`

  ## Example

      iex> reason = ExCodecs.Error.new(:truncated_input).reason
      iex> reason in [:truncated_input, :invalid_data]
      true
  """
  @type error_reason ::
          :unsupported_codec
          | :codec_unavailable
          | :invalid_data
          | :invalid_options
          | :compression_failed
          | :decompression_failed
          | :nif_not_loaded
          | :io_error
          | :truncated_input
          | :output_limit_exceeded
          | :checksum_mismatch

  @typedoc """
  Structured ExCodecs error and exception.

  The fields are `reason` (machine-readable reason), `message` (display text),
  `codec` (associated codec or `nil`), and `details` (diagnostic term or `nil`).

  ## Example

      iex> %ExCodecs.Error{} = error = ExCodecs.Error.new(:io_error, details: :enoent)
      iex> Exception.message(error)
      "An I/O error occurred"
  """
  @type t :: %__MODULE__{
          reason: error_reason(),
          message: String.t(),
          codec: atom() | nil,
          details: term() | nil
        }

  defexception [:reason, :message, :codec, :details]

  @doc """
  Builds a `%ExCodecs.Error{}`.

  ## Arguments

    * `reason` (`error_reason()`) — reason used for matching and to select the
      default message
    * `opts` (`keyword()`) — optional fields:
      * `:message` (`String.t()`) — replaces the default message
      * `:codec` (`atom() | nil`) — identifies the related codec
      * `:details` (`term()`) — stores arbitrary diagnostic context

  ## Returns

  A `t:ExCodecs.Error.t/0` struct. This function never returns an error tuple.

  ## Raises

  Does not raise when called with the declared types. An improper `opts` value
  can raise `FunctionClauseError`.

  ## Examples

      iex> error = ExCodecs.Error.new(:unsupported_codec)
      iex> error.reason
      :unsupported_codec
      iex> error.message
      "The specified codec is not supported"
      iex> error.codec
      nil

      iex> error = ExCodecs.Error.new(:invalid_options, codec: :zstd)
      iex> error.codec
      :zstd
  """
  @spec new(error_reason(), keyword()) :: t()
  def new(reason, opts \\ []) do
    %__MODULE__{
      reason: reason,
      message: Keyword.get(opts, :message, default_message(reason)),
      codec: Keyword.get(opts, :codec),
      details: Keyword.get(opts, :details)
    }
  end

  @doc """
  Builds `{:error, %ExCodecs.Error{}}`.

  ## Arguments

    * `reason` (`error_reason()`) — reason passed to `new/2`
    * `opts` (`keyword()`) — message, codec, and details options accepted by
      `new/2`

  ## Returns

  Always `{:error, t()}`. It has no alternative error reason because the
  supplied `reason` is stored inside the struct.

  ## Raises

  Does not raise when called with the declared types. An improper `opts` value
  can raise `FunctionClauseError`.

  ## Examples

      iex> {:error, error} = ExCodecs.Error.error(:unsupported_codec)
      iex> error.reason
      :unsupported_codec
  """
  @spec error(error_reason(), keyword()) :: {:error, t()}
  def error(reason, opts \\ []) do
    {:error, new(reason, opts)}
  end

  defp default_message(:unsupported_codec), do: "The specified codec is not supported"
  defp default_message(:codec_unavailable), do: "The codec is known but not available at runtime"
  defp default_message(:invalid_data), do: "The input data is invalid for this codec"
  defp default_message(:invalid_options), do: "The provided options are invalid"
  defp default_message(:compression_failed), do: "Compression failed"
  defp default_message(:decompression_failed), do: "Decompression failed"
  defp default_message(:nif_not_loaded), do: "The native NIF library is not loaded"
  defp default_message(:io_error), do: "An I/O error occurred"
  defp default_message(:truncated_input), do: "The input was truncated or incomplete"

  defp default_message(:output_limit_exceeded),
    do: "Decompressed output exceeded the configured max_output_size"

  defp default_message(:checksum_mismatch),
    do: "The stored checksum does not match the data"

  defp default_message(reason), do: "Error: #{reason}"

  @impl true
  @doc """
  Exception message string (for `raise` / `Exception.message/1`).

  ## Arguments

    * `error` (`t()`) — exception whose `message` field is returned

  ## Returns

  The `message` field as a `String.t()`.

  ## Raises

  Does not raise for a `t()` whose `message` field is a string. A value that
  does not match `%ExCodecs.Error{}` raises `FunctionClauseError`.

  ## Example

      iex> error = ExCodecs.Error.new(:invalid_data, message: "not a point cloud")
      iex> Exception.message(error)
      "not a point cloud"
  """
  def message(%__MODULE__{message: message}), do: message

  @doc """
  Returns whether an `{:error, %Error{}}` tuple matches `reason`.

  ## Arguments

    * `result` (`{:error, t()} | term()`) — result to inspect; nonmatching
      terms are accepted and return `false`
    * `reason` (`error_reason()`) — reason that must exactly equal the error's
      `reason` field

  ## Returns

  `true` if `result` is `{:error, %Error{reason: ^reason}}`, else `false`.

  ## Raises

  None; the catch-all clause returns `false` for values of any shape.

  ## Examples

      iex> {:error, error} = ExCodecs.Error.error(:unsupported_codec)
      iex> ExCodecs.Error.matches?({:error, error}, :unsupported_codec)
      true
      iex> ExCodecs.Error.matches?({:error, error}, :invalid_data)
      false
  """
  @spec matches?(term(), error_reason()) :: boolean()
  def matches?({:error, %__MODULE__{reason: reason}}, reason), do: true
  def matches?(_, _), do: false
end
