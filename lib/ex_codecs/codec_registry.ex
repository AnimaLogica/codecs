defmodule ExCodecs.CodecRegistry do
  @moduledoc """
  Shared runtime catalog of codec implementations (ETS-backed).

  Populated at application start (and again if this process restarts). Entries
  carry a category and interface shape: binary codecs use the top-level
  registry API, while spatial entries are dispatched through
  `ExCodecs.Spatial`.

  ## Crash behavior

  The ETS table is owned by this Agent process. If the Agent **crashes**, the
  table is destroyed and only the `:register` callback (built-ins) is replayed
  on restart. **Runtime third-party registrations made via `register/3` or
  `register/5` are lost** and must be re-registered by the caller. If the
  Agent restarts while the table still exists (e.g. via a supervised
  `:restart_for_type`), existing entries are preserved and only overwritten
  by the callback.

  ## Typical use

      iex> ExCodecs.available_codecs()
      [:blosc, :blosc2, :bzip2, :crc32c, :gsplat, :lz4, :ply, :snappy, :spatial_binary, :zstd]

      iex> ExCodecs.supports?(:zstd)
      true
  """

  use Agent

  # The Agent process exists solely to own the named public ETS table
  # (`@table_name`). Its state is the table name itself and is never read
  # after init; a GenServer would be equivalent. A future revision may move
  # the catalog to `:persistent_term` for the read-mostly path.

  @table_name :ex_codecs_registry
  @registry_name __MODULE__

  # Explicit override of the `use Agent`-generated child_spec/1 so it is
  # excluded from the public-doc surface checked by DocumentationTest. The
  # returned spec is identical to the generated default.
  @doc false
  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]}
    }
  end

  @doc """
  Starts the registry Agent and optional re-registration callback.

  ## Arguments

    * `opts` (`keyword()`) — accepts `:register`, a zero-arity function invoked
      after the named ETS table is created or cleared; it defaults to
      `fn -> :ok end`

  ## Returns

    * `{:ok, pid()}` — the named registry Agent started and initialization ran
    * `{:error, {:already_started, pid()}}` — the registry is already running
    * `{:error, reason}` — Agent startup or the registration callback failed

  ## Raises

  With a valid keyword list, startup failures are returned by `Agent`. Passing
  a non-keyword value can raise `FunctionClauseError` while reading options.

  ## Example

  A supervision tree normally starts the registry and supplies the callback:

      children = [
        {ExCodecs.CodecRegistry, register: &MyApp.Codecs.register_all/0}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    register_fun = Keyword.get(opts, :register, fn -> :ok end)

    Agent.start_link(
      fn ->
        case :ets.whereis(@table_name) do
          :undefined ->
            :ets.new(@table_name, [:set, :public, :named_table])

          _tid ->
            # Keep existing entries across registry restarts so third-party
            # registrations survive and readers never see an empty catalog.
            # Built-ins are overwritten by `register_fun` below.
            :ok
        end

        register_fun.()
        @table_name
      end,
      name: @registry_name
    )
  end

  @doc """
  Registers a binary-interface module that exports `encode/2` and `decode/2`.

  ## Arguments

    * `name` (`atom()`) — registry key used for lookups
    * `module` (`module()`) — loaded module exporting `encode/2` and `decode/2`
    * `category` (`atom()`) — grouping key, such as `:compression`

  ## Returns

    * `:ok` — metadata was stored, replacing any entry with the same `name`
    * `{:error, {:invalid_codec_module, module}}` — the module cannot be loaded
      or does not export both codec callbacks

  ## Raises

  May raise `ArgumentError` if the registry ETS table does not exist. A codec's
  optional public `__codec_info__/0` function is called during registration and
  any exception it raises propagates.

  ## Examples

      iex> :ok = ExCodecs.CodecRegistry.register(
      ...>   :zstd,
      ...>   ExCodecs.Compression.Zstd,
      ...>   :compression
      ...> )
      iex> ExCodecs.CodecRegistry.supports?(:zstd)
      true
  """
  @spec register(atom(), module(), atom()) :: :ok | {:error, term()}
  def register(name, module, category) do
    register(name, module, category, :binary)
  end

  @doc """
  Registers a module in the shared catalog with an explicit interface.

  `:binary` entries are dispatched by `ExCodecs.encode/3` / `decode/3`.
  `:spatial` entries are discoverable from the same catalog but dispatched by
  `ExCodecs.Spatial`.

  ## Arguments

    * `name` — catalog key
    * `module` — module exporting `encode/2` and `decode/2`
    * `category` — grouping atom such as `:compression` or `:spatial`
    * `interface` — `:binary` or `:spatial`

  ## Returns

  `:ok` on registration or `{:error, {:invalid_codec_module, module}}`.

  ## Raises

  May raise `ArgumentError` if the registry table has not started, or propagate
  an exception from a module's optional `__codec_info__/0`.

  ## Examples

      iex> :ok = ExCodecs.CodecRegistry.register(
      ...>   :documented_ply,
      ...>   ExCodecs.Spatial.Codec.PLY,
      ...>   :spatial,
      ...>   :spatial
      ...> )
      iex> {:ok, info} = ExCodecs.CodecRegistry.codec_info(:documented_ply)
      iex> {info.category, info.interface}
      {:spatial, :spatial}
      iex> ExCodecs.CodecRegistry.unregister(:documented_ply)
      :ok
  """
  @spec register(atom(), module(), atom(), :binary | :spatial) :: :ok | {:error, term()}
  def register(name, module, category, interface)
      when interface in [:binary, :spatial] do
    register(name, module, category, interface, [])
  end

  @doc """
  Registers a module with an explicit interface and optional metadata overrides.

  Builds the stored `%ExCodecs.Codec{}` from `name`, `module`, `category`, and
  `interface`, then merges capability fields from the module's optional
  `c:ExCodecs.Codec.__codec_info__/0` (when exported). Each key in `metadata`
  overrides the corresponding field from `__codec_info__/0`.

  ## Arguments

    * `name` (`atom()`) — catalog key (always stored; not taken from metadata)
    * `module` (`module()`) — module exporting `encode/2` and `decode/2`
    * `category` (`atom()`) — grouping atom such as `:compression` or `:spatial`
    * `interface` (`:binary | :spatial`) — public API shape for the entry
    * `metadata` (`keyword()`) — optional overrides for capability fields:

      * `:native?` (`boolean()`) — NIF-backed implementation
      * `:streaming?` (`boolean()`) — incremental API available
      * `:configurable?` (`boolean()`) — meaningful codec-specific options
      * `:version` (`String.t() | nil`) — backend version string

      Unknown keys are ignored. Omitted keys keep the value from
      `__codec_info__/0`, or `nil` when that function is not exported.

  ## Returns

    * `:ok` — metadata was stored, replacing any entry with the same `name`
    * `{:error, {:invalid_codec_module, module}}` — the module cannot be loaded
      or does not export both codec callbacks

  ## Raises

  May raise `ArgumentError` if the registry ETS table does not exist. A codec's
  optional `__codec_info__/0` is called during registration and any exception
  it raises propagates.

  ## Persistence

  This entry is stored in an ETS table owned by the registry Agent. If the
  Agent crashes, runtime registrations are **not replayed** — only the
  `:register` callback supplied at `start_link/1` runs on restart. Re-register
  third-party codecs from your own supervision tree if you need crash
  survivability.

  ## Examples

      iex> :ok = ExCodecs.CodecRegistry.register(
      ...>   :documented_spatial_binary,
      ...>   ExCodecs.Spatial.Codec.Binary,
      ...>   :spatial,
      ...>   :spatial,
      ...>   native?: false,
      ...>   streaming?: false,
      ...>   configurable?: false,
      ...>   version: "EXCP 1"
      ...> )
      iex> {:ok, info} = ExCodecs.CodecRegistry.codec_info(:documented_spatial_binary)
      iex> {info.interface, info.version, info.native?}
      {:spatial, "EXCP 1", false}
      iex> ExCodecs.CodecRegistry.unregister(:documented_spatial_binary)
      :ok
  """
  @spec register(atom(), module(), atom(), :binary | :spatial, keyword()) ::
          :ok | {:error, term()}
  def register(name, module, category, interface, metadata)
      when interface in [:binary, :spatial] and is_list(metadata) do
    codec_info = build_codec_info(name, module, category, interface, metadata)

    case ExCodecs.Codec.validates?(module) do
      true ->
        :ets.insert(@table_name, {name, {module, category, codec_info}})
        :ok

      false ->
        {:error, {:invalid_codec_module, module}}
    end
  end

  @doc """
  Registers a known codec with `module: nil` (unavailable).

  ## Arguments

    * `name` (`atom()`) — known codec's registry key
    * `category` (`atom()`) — grouping key, such as `:compression`

  ## Returns

  Always `:ok` after storing a `%ExCodecs.Codec{module: nil}` entry.

  ## Raises

  May raise `ArgumentError` if the registry ETS table does not exist.

  ## Example

      iex> :ok = ExCodecs.CodecRegistry.register_unavailable(:example_optional, :compression)
      iex> {:ok, info} = ExCodecs.CodecRegistry.codec_info(:example_optional)
      iex> {info.module, ExCodecs.CodecRegistry.supports?(:example_optional)}
      {nil, false}
      iex> ExCodecs.CodecRegistry.unregister(:example_optional)
      :ok
  """
  @spec register_unavailable(atom(), atom()) :: :ok
  def register_unavailable(name, category) do
    register_unavailable(name, category, :binary)
  end

  @doc """
  Registers a known codec as unavailable with an explicit interface.

  Stores `%ExCodecs.Codec{module: nil}` with capability fields set to `false`
  and `version: nil`. Use when a codec name is part of the catalog but its
  implementation module cannot be loaded (for example a NIF-backed codec when
  the native library failed to load).

  ## Arguments

    * `name` (`atom()`) — known codec's registry key
    * `category` (`atom()`) — grouping key, such as `:compression` or `:spatial`
    * `interface` (`:binary | :spatial`) — public API shape for the entry

  ## Returns

  Always `:ok` after storing the unavailable entry.

  ## Raises

  May raise `ArgumentError` if the registry ETS table does not exist.

  ## Example

      iex> :ok = ExCodecs.CodecRegistry.register_unavailable(
      ...>   :example_spatial_optional,
      ...>   :spatial,
      ...>   :spatial
      ...> )
      iex> {:ok, info} = ExCodecs.CodecRegistry.codec_info(:example_spatial_optional)
      iex> {info.module, info.interface, ExCodecs.CodecRegistry.supports?(:example_spatial_optional)}
      {nil, :spatial, false}
      iex> ExCodecs.CodecRegistry.unregister(:example_spatial_optional)
      :ok
  """
  @spec register_unavailable(atom(), atom(), :binary | :spatial) :: :ok
  def register_unavailable(name, category, interface)
      when interface in [:binary, :spatial] do
    codec_info = %ExCodecs.Codec{
      name: name,
      category: category,
      interface: interface,
      module: nil,
      native?: false,
      streaming?: false,
      configurable?: false,
      version: nil
    }

    :ets.insert(@table_name, {name, {nil, category, codec_info}})
    :ok
  end

  @doc """
  Deletes a registry entry (tests / hot reload).

  ## Arguments

    * `name` (`atom()`) — registry key to remove

  ## Returns

  Always `:ok`, whether or not an entry existed.

  ## Raises

  Raises `FunctionClauseError` when `name` is not an atom. May raise
  `ArgumentError` if the registry ETS table does not exist.

  ## Example

      iex> :ok = ExCodecs.CodecRegistry.register_unavailable(:temporary_codec, :compression)
      iex> :ok = ExCodecs.CodecRegistry.unregister(:temporary_codec)
      iex> ExCodecs.CodecRegistry.lookup(:temporary_codec)
      {:error, :unsupported_codec}
  """
  @spec unregister(atom()) :: :ok
  def unregister(name) when is_atom(name) do
    :ets.delete(@table_name, name)
    :ok
  end

  @doc """
  Looks up `{module, category, info}` for `name`.

  ## Arguments

    * `name` (`atom()`) — codec registry key

  ## Returns

    * `{:ok, {module() | nil, atom(), ExCodecs.Codec.t()}}` — implementation,
      category, and metadata for a registered name
    * `{:error, :unsupported_codec}` — no entry exists for `name`

  ## Raises

  Raises `FunctionClauseError` when `name` is not an atom. May raise
  `ArgumentError` if the registry ETS table does not exist.

  ## Example

      iex> {:ok, {module, :compression, info}} = ExCodecs.CodecRegistry.lookup(:zstd)
      iex> {module, info.name}
      {ExCodecs.Compression.Zstd, :zstd}
  """
  @spec lookup(atom()) ::
          {:ok, {module() | nil, atom(), ExCodecs.Codec.t()}} | {:error, :unsupported_codec}
  def lookup(name) when is_atom(name) do
    case :ets.lookup(@table_name, name) do
      [{^name, {module, category, info}}] ->
        {:ok, {module, category, info}}

      [] ->
        {:error, :unsupported_codec}
    end
  end

  @doc """
  Sorted list of codec atoms with a non-nil module.

  ## Arguments

  None.

  ## Returns

  A sorted `[atom()]`. Unavailable entries registered with
  `register_unavailable/2` are omitted.

  ## Raises

  May raise `ArgumentError` if the registry ETS table does not exist.

  ## Example

      iex> codecs = ExCodecs.CodecRegistry.available_codecs()
      iex> codecs == Enum.sort(codecs) and :zstd in codecs
      true
  """
  @spec available_codecs() :: [atom()]
  def available_codecs do
    :ets.tab2list(@table_name)
    |> Enum.filter(fn {_name, {module, _category, _info}} -> module != nil end)
    |> Enum.map(fn {name, _} -> name end)
    |> Enum.sort()
  end

  @doc """
  Sorted available catalog names in one category.

  ## Arguments

    * `category` — category atom such as `:compression` or `:spatial`

  ## Returns

  Available names with non-`nil` modules, sorted by name.

  ## Raises

  May raise `ArgumentError` if the registry table has not started.

  ## Examples

      iex> ExCodecs.CodecRegistry.available_codecs(:spatial)
      [:gsplat, :ply, :spatial_binary]
  """
  @spec available_codecs(atom()) :: [atom()]
  def available_codecs(category) when is_atom(category) do
    :ets.tab2list(@table_name)
    |> Enum.filter(fn {_name, {module, cat, _info}} ->
      module != nil and cat == category
    end)
    |> Enum.map(fn {name, _} -> name end)
    |> Enum.sort()
  end

  @doc """
  Sorted list of all registered names (including unavailable).

  ## Arguments

  None.

  ## Returns

  A sorted `[atom()]`, including entries whose module is `nil`.

  ## Raises

  May raise `ArgumentError` if the registry ETS table does not exist.

  ## Example

      iex> :ok = ExCodecs.CodecRegistry.register_unavailable(:documented_optional, :compression)
      iex> :documented_optional in ExCodecs.CodecRegistry.all_codecs()
      true
      iex> ExCodecs.CodecRegistry.unregister(:documented_optional)
      :ok
  """
  @spec all_codecs() :: [atom()]
  def all_codecs do
    :ets.tab2list(@table_name)
    |> Enum.map(fn {name, _} -> name end)
    |> Enum.sort()
  end

  @doc """
  Returns `true` if registered and `module != nil`.

  ## Arguments

    * `name` (`atom()`) — registry key to test

  ## Returns

  `true` only when `name` is registered with a non-`nil` module; otherwise
  `false`.

  ## Raises

  Raises `FunctionClauseError` when `name` is not an atom. May raise
  `ArgumentError` if the registry ETS table does not exist.

  ## Example

      iex> ExCodecs.CodecRegistry.supports?(:zstd)
      true
      iex> ExCodecs.CodecRegistry.supports?(:unknown_codec)
      false
  """
  @spec supports?(atom()) :: boolean()
  def supports?(name) when is_atom(name) do
    case lookup(name) do
      {:ok, {module, _category, _info}} -> module != nil
      {:error, :unsupported_codec} -> false
    end
  end

  @doc """
  Returns `%ExCodecs.Codec{}` for `name`.

  ## Arguments

    * `name` (`atom()`) — codec registry key

  ## Returns

    * `{:ok, ExCodecs.Codec.t()}` — metadata for a registered codec, including
      unavailable codecs
    * `{:error, :unsupported_codec}` — no registry entry exists

  ## Raises

  Raises `FunctionClauseError` when `name` is not an atom. May raise
  `ArgumentError` if the registry ETS table does not exist.

  ## Example

      iex> {:ok, %ExCodecs.Codec{name: :zstd, category: :compression}} =
      ...>   ExCodecs.CodecRegistry.codec_info(:zstd)
      iex> true
      true
  """
  @spec codec_info(atom()) :: {:ok, ExCodecs.Codec.t()} | {:error, :unsupported_codec}
  def codec_info(name) when is_atom(name) do
    case lookup(name) do
      {:ok, {_module, _category, info}} -> {:ok, info}
      {:error, :unsupported_codec} -> {:error, :unsupported_codec}
    end
  end

  @doc """
  Lists `%ExCodecs.Codec{}` for a category atom (e.g. `:compression`).

  ## Arguments

    * `category` (`atom()`) — category to select, such as `:compression`

  ## Returns

  A `[ExCodecs.Codec.t()]` sorted by each struct's `name`. The list includes
  unavailable entries in that category and is empty when none match.

  ## Raises

  Raises `FunctionClauseError` when `category` is not an atom. May raise
  `ArgumentError` if the registry ETS table does not exist.

  ## Example

      iex> codecs = ExCodecs.CodecRegistry.codecs_by_category(:compression)
      iex> Enum.all?(codecs, &match?(%ExCodecs.Codec{category: :compression}, &1))
      true
      iex> Enum.map(codecs, & &1.name) == Enum.sort(Enum.map(codecs, & &1.name))
      true
  """
  @spec codecs_by_category(atom()) :: [ExCodecs.Codec.t()]
  def codecs_by_category(category) when is_atom(category) do
    :ets.tab2list(@table_name)
    |> Enum.filter(fn {_name, {_module, cat, _info}} -> cat == category end)
    |> Enum.map(fn {_name, {_module, _cat, info}} -> info end)
    |> Enum.sort_by(& &1.name)
  end

  defp build_codec_info(name, module, category, interface, metadata) do
    info =
      if Code.ensure_loaded?(module) and function_exported?(module, :__codec_info__, 0) do
        module.__codec_info__()
      else
        %ExCodecs.Codec{}
      end

    %ExCodecs.Codec{
      name: name,
      category: category,
      interface: interface,
      module: module,
      native?: Keyword.get(metadata, :native?, info.native?),
      streaming?: Keyword.get(metadata, :streaming?, info.streaming?),
      configurable?: Keyword.get(metadata, :configurable?, info.configurable?),
      version: Keyword.get(metadata, :version, info.version)
    }
  end
end
