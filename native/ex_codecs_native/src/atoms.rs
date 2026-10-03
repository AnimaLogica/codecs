use rustler::atoms;

atoms! {
    ok,
    error,
    unsupported_codec,
    codec_unavailable,
    invalid_data,
    invalid_options,
    compression_failed,
    decompression_failed,
    nif_not_loaded,
    output_limit_exceeded,
    io_error,
    truncated_input,
    checksum_mismatch,
}
