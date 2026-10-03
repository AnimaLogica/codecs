defmodule ExCodecs.DocumentationTest do
  use ExUnit.Case, async: true

  # Heading/contract linter for moduledocs — exclude with `mix test --exclude lint`
  @moduletag :lint

  @documented_modules [
    ExCodecs,
    ExCodecs.Application,
    ExCodecs.Codec,
    ExCodecs.CodecRegistry,
    ExCodecs.Compression,
    ExCodecs.Compression.Blosc,
    ExCodecs.Compression.Blosc2,
    ExCodecs.Checksum.Crc32c,
    ExCodecs.Compression.Bzip2,
    ExCodecs.Compression.Lz4,
    ExCodecs.Compression.Snappy,
    ExCodecs.Compression.Zstd,
    ExCodecs.Error,
    ExCodecs.Native,
    ExCodecs.Spatial,
    ExCodecs.Spatial.Bounds,
    ExCodecs.Spatial.Codec.Binary,
    ExCodecs.Spatial.Codec.Gsplat,
    ExCodecs.Spatial.Codec.PLY,
    ExCodecs.Spatial.Gaussian,
    ExCodecs.Spatial.GaussianCloud,
    ExCodecs.Spatial.Metadata,
    ExCodecs.Spatial.Point,
    ExCodecs.Spatial.PointCloud,
    ExCodecs.Spatial.Stream,
    ExCodecs.Spatial.Transform
  ]

  @function_sections ["## Arguments", "## Returns", "## Raises", "## Example"]

  test "all visible public functions document their contract and an example" do
    failures =
      for module <- @documented_modules,
          {{kind, name, arity}, annotation, _signature, doc, metadata} <- docs(module),
          kind in [:function, :macro],
          not generated?(annotation, metadata),
          is_map(doc),
          section <- @function_sections,
          not String.contains?(doc["en"], section),
          do: "#{inspect(module)}.#{name}/#{arity} is missing #{section}"

    assert failures == [], Enum.join(failures, "\n")
  end

  test "all visible public types have descriptions and examples" do
    failures =
      for module <- @documented_modules,
          {{:type, name, arity}, _line, _signature, doc, _metadata} <- docs(module),
          do: type_doc_failure(module, name, arity, doc)

    failures = Enum.reject(failures, &is_nil/1)
    assert failures == [], Enum.join(failures, "\n")
  end

  test "all callbacks document a realistic implementation" do
    failures =
      for module <- @documented_modules,
          {{kind, name, arity}, _line, _signature, doc, _metadata} <- docs(module),
          kind in [:callback, :macrocallback],
          do: callback_doc_failure(module, name, arity, doc)

    failures = Enum.reject(failures, &is_nil/1)
    assert failures == [], Enum.join(failures, "\n")
  end

  defp docs(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, _, _, docs} -> docs
      {:error, reason} -> flunk("Could not fetch docs for #{inspect(module)}: #{inspect(reason)}")
    end
  end

  defp generated?(annotation, metadata) do
    annotation_generated? =
      is_list(annotation) and Keyword.get(annotation, :generated, false)

    metadata_generated? =
      (is_map(metadata) and Map.get(metadata, :generated, false)) or
        (is_list(metadata) and Keyword.get(metadata, :generated, false))

    annotation_generated? or metadata_generated?
  end

  defp type_doc_failure(module, name, arity, doc) when not is_map(doc),
    do: "#{inspect(module)}.#{name}/#{arity} has no @typedoc"

  defp type_doc_failure(module, name, arity, %{"en" => text}) do
    if String.contains?(String.downcase(text), "example") do
      nil
    else
      "#{inspect(module)}.#{name}/#{arity} is missing a realistic type example"
    end
  end

  defp callback_doc_failure(module, name, arity, doc) when not is_map(doc),
    do: "#{inspect(module)}.#{name}/#{arity} has no callback documentation"

  defp callback_doc_failure(module, name, arity, %{"en" => text}) do
    required = ["## Arguments", "## Returns", "## Raises", "implementation"]

    case Enum.find(required, &(not String.contains?(String.downcase(text), String.downcase(&1)))) do
      nil -> nil
      missing -> "#{inspect(module)}.#{name}/#{arity} callback is missing #{missing}"
    end
  end
end
