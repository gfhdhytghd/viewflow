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
        "../linux-media/vaapi_encoder.cpp",
        "../linux-media/vaapi_encoder.hpp",
        "../linux-media/device_selection.hpp",
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
        .file(root.join("../linux-media/vaapi_encoder.cpp"))
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
    for library in ["avcodec", "avutil", "EGL", "GLESv2", "dl"] {
        println!("cargo:rustc-link-lib={library}");
    }
}

fn build_gpu_encoder() {
    assert_eq!(
        env::var("CARGO_CFG_TARGET_OS").as_deref(),
        Ok("linux"),
        "native GPU media requires Linux EGL/FFmpeg"
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
        "gpu_dmabuf_encoder.cpp",
        "cuda_dmabuf_encoder.hpp",
        "cuda_encoder_backend.cpp",
        "media_encoder_backend.hpp",
        "vaapi_dmabuf_encoder.cpp",
        "vaapi_dmabuf_encoder.hpp",
        "portable_rgba.hpp",
        "portable_dmabuf_import.cpp",
        "portable_dmabuf_import.hpp",
        "../linux-media/device_selection.hpp",
        "../linux-media/egl_device.hpp",
        "../linux-media/vaapi_encoder.cpp",
        "../linux-media/vaapi_encoder.hpp",
        "gpu_dmabuf_encoder.cuh",
        "alpha_copy_profile.hpp",
        "gpu_import_cleanup.hpp",
        "gpu_dmabuf_encoder_cabi.cpp",
        "gpu_dmabuf_encoder_cabi.h",
        "gpu_rgba_prepare.cu",
        "gpu_rgba_prepare.cuh",
        "gpu_atlas_compose.cu",
        "gpu_atlas_compose.cuh",
        "gpu_sparse_atlas.cu",
        "gpu_sparse_atlas.cuh",
        "sparse_atlas_plan.hpp",
        "gpu_shadow_math.cuh",
        "gpu_shadow_repair.cu",
        "gpu_shadow_repair.cuh",
    ] {
        println!("cargo:rerun-if-changed={}", source.join(name).display());
    }
    println!("cargo:rerun-if-env-changed=VIEWFLOW_ENABLE_CUDA");
    let cuda = env::var("VIEWFLOW_ENABLE_CUDA").unwrap_or_else(|_| "ON".into());
    let status = Command::new("cmake")
        .arg(format!("-DVIEWFLOW_ENABLE_CUDA={cuda}"))
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
    // The CUDA implementation is an optional DSO loaded only for NVIDIA.
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", output.display());
    for library in ["stdc++", "avcodec", "avutil", "EGL", "GLESv2", "dl"] {
        println!("cargo:rustc-link-lib={library}");
    }
}
