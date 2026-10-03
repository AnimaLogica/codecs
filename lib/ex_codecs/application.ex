defmodule ExCodecs.Application do
  @moduledoc """
  OTP Application callback module for ExCodecs.

  Starts the shared `ExCodecs.CodecRegistry` catalog and registers all built-in
  binary and spatial codecs during application startup.
  """

  use Application

  @impl true
  @doc """
  Starts the ExCodecs supervision tree.

  This callback starts `ExCodecs.CodecRegistry`, registers every built-in
  codec entry, and supervises the registry with a `:one_for_one`
  strategy. It is invoked by OTP when the `:ex_codecs` application starts;
  application code should normally use `Application.ensure_all_started/1`
  instead of calling this function directly.

  ## Arguments

    * `type` — `Application.start_type()`. OTP supplies `:normal`,
      `{:takeover, node}`, or `{:failover, node}`; ExCodecs does not vary its
      startup behavior by type.
    * `args` — startup term configured for the application. ExCodecs ignores
      this value.

  ## Returns

    * `{:ok, supervisor_pid}` when the supervisor and registry start.
    * `{:error, reason}` when `Supervisor.start_link/2` cannot start the
      supervision tree.
    * `{:ok, supervisor_pid, state}` is permitted by the
      `Application.start/2` callback contract, but ExCodecs does not currently
      return that form.

  ## Raises

  This callback does not deliberately raise. OTP or supervisor internals may
  exit the calling process for unrecoverable startup failures.

  ## Example

      iex> {:ok, _apps} = Application.ensure_all_started(:ex_codecs)
      iex> Process.whereis(ExCodecs.Supervisor) |> is_pid()
      true
      iex> ExCodecs.supports?(:zstd)
      true

  ## Callback implementation

  An OTP application that embeds a similar registry can use the same shape.
  Note: `ExCodecs.CodecRegistry` registers under a fixed global name, so the
  example below is for a **separate** registry module, not a second instance
  of the library's own.

      defmodule MyApp.Application do
        use Application

        @impl Application
        def start(_type, _args) do
          children = [{MyApp.CodecRegistry, register: fn -> :ok end}]
          Supervisor.start_link(children,
            strategy: :one_for_one,
            name: MyApp.Supervisor
          )
        end
      end
  """
  @spec start(Application.start_type(), term()) ::
          {:ok, pid()} | {:error, term()} | {:ok, pid(), term()}
  def start(_type, _args) do
    children = [
      {ExCodecs.CodecRegistry, register: &register_all_codecs/0}
    ]

    opts = [strategy: :one_for_one, name: ExCodecs.Supervisor]

    Supervisor.start_link(children, opts)
  end

  @doc false
  def register_all_codecs do
    codecs = [
      {:zstd, ExCodecs.Compression.Zstd, :compression, :binary, []},
      {:lz4, ExCodecs.Compression.Lz4, :compression, :binary, []},
      {:snappy, ExCodecs.Compression.Snappy, :compression, :binary, []},
      {:bzip2, ExCodecs.Compression.Bzip2, :compression, :binary, []},
      {:blosc, ExCodecs.Compression.Blosc, :compression, :binary, []},
      {:blosc2, ExCodecs.Compression.Blosc2, :compression, :binary, []},
      {:crc32c, ExCodecs.Checksum.Crc32c, :checksum, :binary, []},
      {:ply, ExCodecs.Spatial.Codec.PLY, :spatial, :spatial,
       [native?: false, streaming?: false, configurable?: true, version: "PLY 1.0"]},
      {:spatial_binary, ExCodecs.Spatial.Codec.Binary, :spatial, :spatial,
       [native?: false, streaming?: false, configurable?: false, version: "EXCP 1"]},
      {:gsplat, ExCodecs.Spatial.Codec.Gsplat, :spatial, :spatial,
       [native?: false, streaming?: false, configurable?: false, version: "GSPL 1"]}
    ]

    nif_ok? = ExCodecs.Native.nif_loaded?()

    for {name, module, category, interface, metadata} <- codecs do
      if codec_available?(module, nif_ok?) do
        ExCodecs.CodecRegistry.register(name, module, category, interface, metadata)
      else
        ExCodecs.CodecRegistry.register_unavailable(name, category, interface)
      end
    end

    :ok
  end

  @doc false
  def codec_available?(module, nif_ok?) do
    loadable? =
      Code.ensure_loaded?(module) and function_exported?(module, :encode, 2) and
        function_exported?(module, :decode, 2)

    native? =
      loadable? and
        function_exported?(module, :__codec_info__, 0) and
        match?(%{native?: true}, module.__codec_info__())

    loadable? and (not native? or nif_ok?)
  end
end
