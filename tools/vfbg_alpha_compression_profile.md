# Offline VFBG alpha compression profile

These tools only read a regular, bounded VFBG fixture or VFAR v1 alpha payload and print statistics. They do not write image data, contact a capture service, or measure GPU/transport latency.

Run the production VFAR implementation and its byte-exact decode check:

```sh
cargo run -p viewflowd --example vfbg_alpha_vfar_profile -- INPUT_VFBG_OR_VFAR
```

Run Node's built-in zlib comparison (deflate levels 1, 3, and 6):

```sh
node tools/vfbg_alpha_deflate_profile.mjs INPUT_VFBG_OR_VFAR
```

Both outputs include the source fixture SHA-256, dimensions, stride, alpha byte count, compressed sizes, elapsed host microseconds, and an exact alpha roundtrip result. The two timings are separate offline CPU measurements and must not be interpreted as real-time capture or presentation performance.
