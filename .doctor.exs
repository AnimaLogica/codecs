%Doctor.Config{
  ignore_modules: [
    # Internal ABI facade: public for codecs, not part of the Hex API surface.
    ExCodecs.Spatial.Accel,
    # Shared stream_decode source helper; not a user-facing codec.
    ExCodecs.Spatial.Codec.StreamSource
  ],
  ignore_paths: [],
  min_module_doc_coverage: 40,
  min_module_spec_coverage: 0,
  min_overall_doc_coverage: 50,
  min_overall_moduledoc_coverage: 100,
  min_overall_spec_coverage: 0,
  exception_moduledoc_required: true,
  raise: true,
  reporter: Doctor.Reporters.Full,
  struct_type_spec_required: true,
  umbrella: false
}
