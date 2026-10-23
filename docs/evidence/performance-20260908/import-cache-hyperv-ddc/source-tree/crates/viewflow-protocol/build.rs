fn main() {
    println!("cargo:rerun-if-changed=../../protocol/viewflow/v1/control.proto");
    let protoc = protoc_bin_vendored::protoc_bin_path()
        .expect("a vendored protoc binary must be available for this target");
    let mut config = prost_build::Config::new();
    config.protoc_executable(protoc);
    config
        .compile_protos(
            &["../../protocol/viewflow/v1/control.proto"],
            &["../../protocol"],
        )
        .expect("viewflow protocol must compile");
}
