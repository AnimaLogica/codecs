mod atoms;
mod blosc1_codec;
mod blosc2_codec;
mod bzip2_codec;
mod crc32c_codec;
mod lz4_codec;
mod snappy_codec;
mod spatial;
mod util;
mod zstd_codec;

rustler::init!("Elixir.ExCodecs.Native");

#[rustler::nif]
fn codec_versions() -> std::collections::HashMap<&'static str, String> {
    let mut versions = std::collections::HashMap::new();
    versions.insert("zstd", zstd_codec::version());
    versions.insert("lz4", lz4_codec::version());
    versions.insert("snappy", snappy_codec::version());
    versions.insert("bzip2", bzip2_codec::version());
    versions.insert("blosc", "blosc1-chunk/pure-rust".to_string());
    versions.insert("blosc2", blosc2_codec::version());
    versions.insert("crc32c", crc32c_codec::version());
    versions.insert("spatial", "excp-gspl-ply-1".to_string());
    versions
}
