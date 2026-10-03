defmodule ExCodecs.Compression.BloscTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest ExCodecs.Compression.Blosc

  alias ExCodecs.Compression.Blosc

  @fixture_dir Path.expand("../../fixtures/blosc1", __DIR__)
  @cnames [:blosclz, :lz4, :lz4hc, :zlib, :zstd]

  # Same deterministic source the fixture generator uses.
  defp pattern(n), do: for(i <- 0..(n - 1)//1, into: <<>>, do: <<rem(i * 7 + div(i, 3), 251)>>)

  describe "numcodecs / c-blosc 1.x golden chunks" do
    for {name, size} <- [
          {"lz4_shuffle_t8", 300_000},
          {"zstd_bitshuffle_t4", 300_000},
          {"blosclz_noshuffle_t1", 300_000},
          {"blosclz_shuffle_t2_split", 300_000},
          {"zlib_shuffle_t2", 70_001},
          {"lz4hc_shuffle_t8", 4_096},
          {"lz4_small_memcpyed", 100}
        ] do
      test "decodes #{name}" do
        chunk = File.read!(Path.join(@fixture_dir, unquote(name) <> ".bin"))
        assert {:ok, decoded} = ExCodecs.decode(:blosc, chunk)
        assert decoded == pattern(unquote(size))
      end
    end
  end

  describe "encode" do
    test "writes the Blosc1 header (format version 2)" do
      data = pattern(300_000)

      for cname <- @cnames, shuffle <- [:none, :byte, :bit] do
        assert {:ok,
                <<2, 1, flags, 8, nbytes::little-32, _blocksize::little-32, cbytes::little-32,
                  _::binary>> = chunk} =
                 Blosc.encode(data, cname: cname, shuffle: shuffle, typesize: 8)

        assert nbytes == byte_size(data)
        assert cbytes == byte_size(chunk)
        # never split, never memcpyed for this compressible input
        assert Bitwise.band(flags, 0x10) == 0x10
        assert Bitwise.band(flags, 0x02) == 0
      end
    end

    test "compressor format bits match c-blosc" do
      data = pattern(10_000)

      for {cname, format} <- [blosclz: 0, lz4: 1, lz4hc: 1, zlib: 3, zstd: 4] do
        {:ok, <<2, _, flags, _::binary>>} = Blosc.encode(data, cname: cname)
        assert Bitwise.bsr(flags, 5) == format, "#{cname}"
      end
    end

    test "clevel 0, tiny and incompressible inputs are stored uncompressed" do
      random = :crypto.strong_rand_bytes(5_000)

      for {data, opts} <- [{pattern(5_000), [clevel: 0]}, {"tiny", []}, {random, [shuffle: :none]}] do
        assert {:ok, <<2, 1, flags, _::binary>> = chunk} = Blosc.encode(data, opts)
        assert Bitwise.band(flags, 0x02) == 0x02
        assert byte_size(chunk) == byte_size(data) + 16
        assert {:ok, ^data} = Blosc.decode(chunk, [])
      end
    end

    test "empty input matches c-blosc's layout" do
      assert {:ok, <<2, 1, 0x33, 1, 0::32, 1::little-32, 16::little-32>>} =
               Blosc.encode("", cname: :lz4, shuffle: :byte, typesize: 1)
    end

    test "rejects invalid options" do
      for opts <- [
            [cname: :snappy],
            [cname: :brotli],
            [clevel: 10],
            [clevel: -1],
            [shuffle: :sideways],
            [typesize: 0],
            [typesize: 256]
          ] do
        assert {:error, %ExCodecs.Error{reason: :invalid_options, codec: :blosc}} =
                 Blosc.encode("data", opts),
               inspect(opts)
      end
    end

    test "rejects non-binary input" do
      assert {:error, %ExCodecs.Error{reason: :invalid_data}} = Blosc.encode(:nope, [])
      assert {:error, %ExCodecs.Error{reason: :invalid_data}} = Blosc.decode(:nope, [])
    end
  end

  describe "decode" do
    test "also reads Blosc2 chunks" do
      data = pattern(20_000)
      {:ok, blosc2_chunk} = ExCodecs.encode(:blosc2, data, cname: :zstd)
      assert {:ok, ^data} = Blosc.decode(blosc2_chunk, [])
    end

    test "honours max_output_size" do
      {:ok, chunk} = Blosc.encode(pattern(10_000), [])

      assert {:error, %ExCodecs.Error{reason: :output_limit_exceeded}} =
               Blosc.decode(chunk, max_output_size: 1_000)
    end

    test "rejects corrupt chunks" do
      {:ok, <<header::binary-size(16), rest::binary>>} = Blosc.encode(pattern(50_000), cname: :lz4)
      corrupt = header <> :binary.copy(<<0xFF>>, byte_size(rest))
      assert {:error, %ExCodecs.Error{}} = Blosc.decode(corrupt, [])
    end
  end

  property "round-trips arbitrary data for every compressor and filter" do
    check all(
            data <- StreamData.binary(max_length: 20_000),
            cname <- StreamData.member_of(@cnames),
            shuffle <- StreamData.member_of([:none, :byte, :bit]),
            typesize <- StreamData.integer(1..16),
            clevel <- StreamData.integer(0..9),
            max_runs: 200
          ) do
      {:ok, chunk} =
        Blosc.encode(data, cname: cname, shuffle: shuffle, typesize: typesize, clevel: clevel)

      assert {:ok, ^data} = Blosc.decode(chunk, [])
    end
  end
end
