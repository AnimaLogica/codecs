defmodule ExCodecs.Checksum.Crc32cTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest ExCodecs.Checksum.Crc32c

  alias ExCodecs.Checksum.Crc32c

  # RFC 3720 (iSCSI) appendix B.4 test vectors
  @vectors [
    {"", 0x00000000},
    {"123456789", 0xE3069283},
    {:binary.copy(<<0>>, 32), 0x8A9136AA},
    {:binary.copy(<<0xFF>>, 32), 0x62A8AB43},
    {:binary.list_to_bin(Enum.to_list(0..31)), 0x46DD794E},
    {:binary.list_to_bin(Enum.to_list(31..0//-1)), 0x113FDB5C}
  ]

  test "matches the RFC 3720 test vectors" do
    for {data, expected} <- @vectors do
      assert {:ok, ^expected} = Crc32c.checksum(data)
    end
  end

  test "encode appends the little-endian checksum" do
    assert {:ok, "123456789" <> <<0x83, 0x92, 0x06, 0xE3>>} = Crc32c.encode("123456789", [])
  end

  test "decode rejects a wrong checksum" do
    assert {:error, %ExCodecs.Error{reason: :checksum_mismatch, codec: :crc32c}} =
             Crc32c.decode("123456789" <> <<0x83, 0x92, 0x06, 0xE4>>, [])
  end

  test "decode rejects input shorter than the checksum" do
    assert {:error, %ExCodecs.Error{reason: :truncated_input, codec: :crc32c}} =
             Crc32c.decode(<<1, 2, 3>>, [])
  end

  test "is registered as a checksum codec" do
    assert :crc32c in ExCodecs.available_codecs()
    assert {:ok, framed} = ExCodecs.encode(:crc32c, "abc")
    assert {:ok, "abc"} = ExCodecs.decode(:crc32c, framed)
  end

  test "rejects non-binary input" do
    assert {:error, %ExCodecs.Error{reason: :invalid_data}} = Crc32c.encode(:nope, [])
    assert {:error, %ExCodecs.Error{reason: :invalid_data}} = Crc32c.decode(:nope, [])
    assert {:error, %ExCodecs.Error{reason: :invalid_data}} = Crc32c.checksum(:nope)
  end

  property "decode(encode(x)) == x and any flipped bit is detected" do
    check all(data <- StreamData.binary(min_length: 1, max_length: 4_096), max_runs: 200) do
      {:ok, framed} = Crc32c.encode(data, [])
      assert {:ok, ^data} = Crc32c.decode(framed, [])

      bit = rem(byte_size(data) * 7, bit_size(framed))
      <<pre::bitstring-size(bit), b::1, post::bitstring>> = framed
      flipped = <<pre::bitstring, 1 - b::1, post::bitstring>>
      assert {:error, %ExCodecs.Error{reason: :checksum_mismatch}} = Crc32c.decode(flipped, [])
    end
  end
end
