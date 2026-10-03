# Runtime Codec Discovery

ExCodecs uses a shared runtime catalog to discover, validate, and query binary
and spatial codecs. This guide explains how the ETS-backed registry works, how
it enables graceful degradation, and how to extend it with custom binary
codecs.

## The Codec Registry

The `ExCodecs.CodecRegistry` module manages a mapping from codec names (atoms) to their implementations and metadata. It is backed by an ETS table for fast, concurrent lookups without process bottlenecks.

### Architecture

```
Application Start
       |
       v
  ExCodecs.Application.start/2
       |
       v
  CodecRegistry.start_link()  --creates-->  ETS table (:ex_codecs_registry)
       |
       v
  register_all_codecs()  --populates-->  ETS table
       |
       v
  Ready for lookups
```

The registry starts before any codec modules are registered. During application startup, `ExCodecs.Application` iterates through the known codecs and attempts to register each one:

```elixir
codecs = [
  {:zstd, ExCodecs.Compression.Zstd, :compression},
  {:lz4, ExCodecs.Compression.Lz4, :compression},
  {:snappy, ExCodecs.Compression.Snappy, :compression},
  {:bzip2, ExCodecs.Compression.Bzip2, :compression},
  {:blosc2, ExCodecs.Compression.Blosc2, :compression}
]

for {name, module, category} <- codecs do
  if nif_loaded?() and Code.ensure_loaded?(module) and function_exported?(module, :encode, 2) do
    CodecRegistry.register(name, module, category)
  else
    CodecRegistry.register_unavailable(name, category)
  end
end
```

### ETS Backend

The registry uses a named ETS table (`:ex_codecs_registry`) with the `:set` and `:public` options:

- **`:set`**: Each key (codec name) maps to exactly one entry.
- **`:public`**: Any process can read and write, enabling concurrent access without going through the Agent.

The Agent process (`ExCodecs.CodecRegistry`) owns the ETS table and ensures it is created during startup. Subsequent lookups go directly to ETS without process serialization.

### Registry Entry Format

Each entry in the ETS table is a tuple:

```elixir
{name :: atom(), {module :: module() | nil, category :: atom(), info :: %ExCodecs.Codec{}}}
```

For an available codec:
```elixir
{:zstd, {ExCodecs.Compression.Zstd, :compression, %ExCodecs.Codec{name: :zstd, ...}}}
```

For an unavailable codec:
```elixir
{:zstd, {nil, :compression, %ExCodecs.Codec{name: :zstd, module: nil, native?: false, ...}}}
```

The distinction between "known but unavailable" and "unknown" is important:

- **Known but unavailable**: The codec is registered in the table with
  `module: nil`. Its implementation could not be loaded (for compression this
  commonly means the native NIF is unavailable). `supports?/1` returns
  `false`, but `codec_info/1` still returns metadata.

- **Unknown**: The codec name is not in the table at all. `lookup/1` returns `{:error, :unsupported_codec}`.

## Querying the Registry

### Available Codecs

List all catalog entries that are loaded and functional:

```elixir
ExCodecs.available_codecs()
# => [:blosc, :blosc2, :bzip2, :crc32c, :gsplat, :lz4, :ply, :snappy, :spatial_binary, :zstd]

ExCodecs.available_codecs(:compression)
# => [:blosc, :blosc2, :bzip2, :lz4, :snappy, :zstd]

ExCodecs.available_codecs(:spatial)
# => [:gsplat, :ply, :spatial_binary]
```

This filters out codecs where the module is `nil` (unavailable). Only codecs you can actually use are included.

### Check If a Codec Is Available

```elixir
ExCodecs.supports?(:zstd)    # => true
ExCodecs.supports?(:unknown)  # => false
```

Use this before encoding or decoding when you need conditional behavior:

```elixir
def compress_data(data) do
  if ExCodecs.supports?(:zstd) do
    ExCodecs.encode(:zstd, data, level: 3)
  else
    {:ok, data}  # Fallback: return uncompressed
  end
end
```

### Get Codec Metadata

```elixir
{:ok, info} = ExCodecs.codec_info(:zstd)
# => %ExCodecs.Codec{
#      name: :zstd,
#      category: :compression,
#      interface: :binary,
#      module: ExCodecs.Compression.Zstd,
#      native?: true,
#      streaming?: false,
#      configurable?: true,
#      version: "structured-zstd-0.0.48"
#    }

info.streaming?     # => false
info.configurable?  # => true
info.version        # => "structured-zstd-0.0.48"
```

This is useful for checking codec capabilities:

```elixir
def compress_with_fallback(data, codec \\ :zstd) do
  {:ok, info} = ExCodecs.codec_info(codec)

  opts = if info.configurable?, do: [level: 5], else: []
  ExCodecs.encode(codec, data, opts)
end
```

### List Codecs by Category

```elixir
ExCodecs.Compression.available_codecs()
# => [%ExCodecs.Codec{name: :blosc2, ...}, %ExCodecs.Codec{name: :bzip2, ...}, ...]
```

Built-ins currently occupy `:compression` and `:spatial`. The `interface`
metadata records whether operations use the top-level binary API or the
specialized spatial API.

### Direct Lookup

```elixir
{:ok, {module, category, info}} = ExCodecs.CodecRegistry.lookup(:zstd)
# => {ExCodecs.Compression.Zstd, :compression, %ExCodecs.Codec{...}}
```

## Graceful Degradation

One of the key design goals of ExCodecs is **graceful degradation**: the application should not crash if a native NIF fails to load.

### How It Works

1. During application startup, the application checks if the Rustler NIF is available.
2. If the NIF is loaded, codecs are registered normally with their modules.
3. If the NIF is not loaded, codecs are registered as "unavailable" with `module: nil`.
4. `ExCodecs.encode/3` and `ExCodecs.decode/3` check if the module is `nil` before calling it, returning `{:error, %ExCodecs.Error{reason: :codec_unavailable}}` for unavailable codecs.

### NIF Loading Failure Scenarios

The NIF may fail to load when:

- **Unsupported platform**: The precompiled NIF binary is not available for the current OS/architecture combination.
- **Missing shared library**: A system-level dependency is missing.
- **NIF version mismatch**: The BEAM NIF version is not compatible with the compiled NIF.
- **Rustler compilation failure**: The Rust compiler is not available and no precompiled binary exists.

In any of these cases, the registry still works. You can query `available_codecs/0` to get the list of functional codecs and `supports?/1` to check specific codecs.

### Pattern for Graceful Fallback

```elixir
defmodule MyDataPipeline do
  @preferred_codec :zstd
  @fallback_codec :lz4

  def compress(data) do
    cond do
      ExCodecs.supports?(@preferred_codec) ->
        ExCodecs.encode(@preferred_codec, data, level: 3)

      ExCodecs.supports?(@fallback_codec) ->
        ExCodecs.encode(@fallback_codec, data, level: 1)

      true ->
        # No compression available, return data as-is
        {:ok, data}
    end
  end
end
```

### Error Handling for Unavailable Codecs

```elixir
case ExCodecs.encode(:zstd, data) do
  {:ok, compressed} ->
    handle_success(compressed)

  {:error, %ExCodecs.Error{reason: :codec_unavailable}} ->
    # The NIF is not loaded; fall back to an alternative
    ExCodecs.encode(:lz4, data)

  {:error, %ExCodecs.Error{reason: :unsupported_codec}} ->
    # The codec name is not registered at all
    {:error, :unknown_codec}

  {:error, %ExCodecs.Error{reason: :compression_failed}} ->
    # The NIF loaded but compression failed (e.g., corrupt data)
    {:error, :compression_error}
end
```

## Registering Custom Codecs

You can add custom codecs at runtime by implementing the `ExCodecs.Codec` behaviour and registering them.

### Step 1: Implement the Behaviour

```elixir
defmodule MyApp.Codecs.Rot13 do
  @behaviour ExCodecs.Codec

  def __codec_info__ do
    %ExCodecs.Codec{
      name: :rot13,
      category: :encoding,
      module: __MODULE__,
      native?: false,
      streaming?: false,
      configurable?: false,
      version: "1.0.0"
    }
  end

  @impl true
  def encode(data, _opts) when is_binary(data) do
    {:ok, rot13(data)}
  end

  @impl true
  def decode(data, _opts) when is_binary(data) do
    {:ok, rot13(data)}
  end

  defp rot13(data) do
    for <<byte <- data>>, into: <<>> do
      cond do
        byte in ?a..?z -> <<rem(byte - ?a + 13, 26) + ?a>>
        byte in ?A..?Z -> <<rem(byte - ?A + 13, 26) + ?A>>
        true -> <<byte>>
      end
    end
  end
end
```

### Step 2: Register the Codec

```elixir
:ok = ExCodecs.CodecRegistry.register(:rot13, MyApp.Codecs.Rot13, :encoding)
```

### Step 3: Use It

```elixir
ExCodecs.supports?(:rot13)        # => true
ExCodecs.encode(:rot13, "hello")  # => {:ok, "uryyb"}
ExCodecs.decode(:rot13, "uryyb")  # => {:ok, "hello"}
```

### Registration Validation

When registering a codec, `CodecRegistry.register/3` validates that the module implements the required functions:

```elixir
ExCodecs.Codec.validates?(MyApp.Codecs.Rot13)
# => true  (module exports encode/2 and decode/2)

ExCodecs.Codec.validates?(SomeModuleWithoutCodecBehaviour)
# => false
```

If validation fails, registration returns an error:

```elixir
ExCodecs.CodecRegistry.register(:bad_codec, NotAModule, :compression)
# => {:error, {:invalid_codec_module, NotAModule}}
```

## All vs. Available Codecs

The registry distinguishes between "all registered codecs" and "available codecs":

```elixir
# All codecs known to the registry (including unavailable ones)
ExCodecs.CodecRegistry.all_codecs()
# => [:blosc, :blosc2, :bzip2, :crc32c, :gsplat, :lz4, :ply, :snappy, :spatial_binary, :zstd]

# Only entries whose implementation is loaded and functional
ExCodecs.CodecRegistry.available_codecs()
# => [:bzip2, :gsplat, :lz4, :ply, :snappy, :spatial_binary, :zstd]
# (:blosc2 is unavailable in this example)
```

The set of available codecs may change if the NIF is reloaded. In normal operation, once the NIF loads successfully, all built-in codecs are available.

## Thread Safety

The ETS table is created with `:public` access, meaning reads and writes are atomic and thread-safe. In practice:

- **Reads are lock-free.** `lookup/1`, `available_codecs/0`, and `supports?/1` do not block.
- **Writes are atomic.** `register/3` and `register_unavailable/2` use `:ets.insert/2`, which is atomic.
- **No transaction across multiple operations.** The list of available codecs could change between calling `available_codecs/0` and using a codec. Use `supports?/1` immediately before use if availability may change.

In most deployments, all codecs are registered once at startup and never change. Concurrent reads are safe and fast.

## Summary

- The registry uses ETS for fast, lock-free lookups without process bottlenecks.
- Codecs are registered at startup; unavailable ones (NIF not loaded) are marked but not removed.
- `supports?/1` and `available_codecs/0` enable runtime checks.
- Custom codecs can be registered by implementing the `ExCodecs.Codec` behaviour and calling `CodecRegistry.register/3`.
- The distinction between "known" and "available" codecs enables graceful degradation when native libraries are missing.