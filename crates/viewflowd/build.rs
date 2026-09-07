use std::{env, path::PathBuf, process::Command};

fn main() {
    if env::var_os("CARGO_FEATURE_NATIVE_GPU_NVENC").is_some() {
        build_gpu_encoder();
    }
    if env::var_os("CARGO_FEATURE_NATIVE_NVENC").is_none() {
        return;
    }
    assert!(
        env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux"),
        "viewflowd native-nvenc is supported only on Linux"
    );
    let root = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("manifest directory"))
        .join("../../platform/nvenc-encoder");
    for file in [
        "nvenc_encoder.cpp",
        "nvenc_encoder_cabi.cpp",
        "nvenc_encoder.hpp",
        "nvenc_encoder_cabi.h",
    ] {
        println!("cargo:rerun-if-changed={}", root.join(file).display());
    }
    let status = Command::new("pkg-config")
        .args(["--exists", "libavcodec", "libavutil"])
        .status()
        .expect("run pkg-config for native-nvenc");
    assert!(
        status.success(),
        "native-nvenc requires pkg-config libavcodec libavutil development headers"
    );
    let cflags = Command::new("pkg-config")
        .args(["--cflags-only-I", "libavcodec", "libavutil"])
        .output()
        .expect("read libav include flags from pkg-config");
    assert!(cflags.status.success(), "read native-nvenc include flags");
    let mut build = cc::Build::new();
    build
        .cpp(true)
        .std("c++20")
        .file(root.join("nvenc_encoder.cpp"))
        .file(root.join("nvenc_encoder_cabi.cpp"))
        .include(&root);
    for flag in String::from_utf8(cflags.stdout)
        .expect("pkg-config cflags are UTF-8")
        .split_whitespace()
    {
        if let Some(path) = flag.strip_prefix("-I") {
            build.include(path);
        }
    }
    build
        .flag_if_supported("-Wall")
        .flag_if_supported("-Wextra")
        .flag_if_supported("-Wpedantic")
        .flag_if_supported("-Werror")
        .compile("viewflow_nvenc_encoder");
    for library in ["avcodec", "avutil"] {
        println!("cargo:rustc-link-lib={library}");
    }
}

fn build_gpu_encoder() {
    assert_eq!(
        env::var("CARGO_CFG_TARGET_OS").as_deref(),
        Ok("linux"),
        "native-gpu-nvenc requires Linux EGL/CUDA"
    );
    assert_eq!(
        env::var("HOST").ok(),
        env::var("TARGET").ok(),
        "native-gpu-nvenc currently requires a native build"
    );
    let source = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("manifest directory"))
        .join("../../platform/nvenc-encoder");
    let output =
        PathBuf::from(env::var_os("OUT_DIR").expect("Cargo output directory")).join("gpu-encoder");
    for name in [
        "CMakeLists.txt",
        "gpu_dmabuf_encoder.cu",
        "gpu_dmabuf_encoder.cuh",
        "gpu_import_cleanup.hpp",
        "gpu_dmabuf_encoder_cabi.cpp",
        "gpu_dmabuf_encoder_cabi.h",
        "gpu_rgba_prepare.cu",
        "gpu_rgba_prepare.cuh",
        "gpu_atlas_compose.cu",
        "gpu_atlas_compose.cuh",
        "gpu_shadow_math.cuh",
        "gpu_shadow_repair.cu",
        "gpu_shadow_repair.cuh",
    ] {
        println!("cargo:rerun-if-changed={}", source.join(name).display());
    }
    let status = Command::new("cmake")
        .arg("-S")
        .arg(&source)
        .arg("-B")
        .arg(&output)
        .args([
            "-DVIEWFLOW_BUILD_GPU_DMABUF_ENCODER=ON",
            "-DVIEWFLOW_TEST_GPU_EXPIRY=OFF",
            "-DBUILD_TESTING=OFF",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
        ])
        .status()
        .expect("configure GPU encoder with CMake");
    assert!(status.success(), "GPU encoder CMake configuration failed");
    let status = Command::new("cmake")
        .arg("--build")
        .arg(&output)
        .args(["--target", "viewflow-gpu-dmabuf-encoder", "--parallel", "2"])
        .status()
        .expect("build GPU encoder");
    assert!(status.success(), "GPU encoder native build failed");
    println!("cargo:rustc-link-search=native={}", output.display());
    println!("cargo:rustc-link-lib=static=viewflow-gpu-dmabuf-encoder");
    for directory in ["/opt/cuda/lib64", "/usr/local/cuda/lib64"] {
        if std::path::Path::new(directory).is_dir() {
            println!("cargo:rustc-link-search=native={directory}");
        }
    }
    for library in [
        "stdc++", "avcodec", "avutil", "EGL", "GLESv2", "cudart", "cuda",
    ] {
        println!("cargo:rustc-link-lib={library}");
    }
}
