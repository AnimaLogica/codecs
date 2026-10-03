#!/usr/bin/env python3
"""Regenerate Blosc1 golden chunks with numcodecs (c-blosc 1.x).

    pip install numcodecs
    python test/fixtures/blosc1/generate.py

The source data is the deterministic pattern used by the tests:
byte i = (i * 7 + i // 3) % 251.
"""
from pathlib import Path

from numcodecs import Blosc, blosc

HERE = Path(__file__).parent
CASES = [
    # name, cname, shuffle, typesize, size
    ("lz4_shuffle_t8", "lz4", Blosc.SHUFFLE, 8, 300_000),
    ("zstd_bitshuffle_t4", "zstd", Blosc.BITSHUFFLE, 4, 300_000),
    ("blosclz_noshuffle_t1", "blosclz", Blosc.NOSHUFFLE, 1, 300_000),
    ("blosclz_shuffle_t2_split", "blosclz", Blosc.SHUFFLE, 2, 300_000),
    ("zlib_shuffle_t2", "zlib", Blosc.SHUFFLE, 2, 70_001),
    ("lz4hc_shuffle_t8", "lz4hc", Blosc.SHUFFLE, 8, 4_096),
    ("lz4_small_memcpyed", "lz4", Blosc.SHUFFLE, 1, 100),
]


def pattern(n):
    return bytes((i * 7 + i // 3) % 251 for i in range(n))


for name, cname, shuffle, typesize, size in CASES:
    chunk = blosc.compress(pattern(size), cname.encode(), 5, shuffle, typesize=typesize)
    assert chunk[0] == 2, f"{name}: not a Blosc1 chunk"
    (HERE / f"{name}.bin").write_bytes(chunk)
    print(name, len(chunk), "bytes, flags", hex(chunk[2]))

print("c-blosc", blosc.VERSION_STRING)
