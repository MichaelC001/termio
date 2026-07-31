use std::env;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const REQUIRED_ZIG_VERSION: &str = "0.15.2";

fn zig_target(target: &str) -> &str {
    match target {
        "aarch64-apple-darwin" => "aarch64-macos",
        "x86_64-apple-darwin" => "x86_64-macos",
        "aarch64-unknown-linux-musl" => "aarch64-linux-musl",
        "x86_64-unknown-linux-musl" => "x86_64-linux-musl",
        other => panic!(
            "unsupported libghostty-vt target {other}; Linux GNU targets are intentionally rejected"
        ),
    }
}

fn check_zig_version(zig: &OsString) {
    let output = Command::new(zig)
        .arg("version")
        .output()
        .expect("failed to execute Zig; set ZIG to the Zig 0.15.2 executable");
    assert!(output.status.success(), "`zig version` failed");

    let version = String::from_utf8(output.stdout).expect("Zig version was not UTF-8");
    assert_eq!(
        version.trim(),
        REQUIRED_ZIG_VERSION,
        "libghostty-vt 1.3.2 requires Zig {REQUIRED_ZIG_VERSION}"
    );
}

fn build_libghostty(zig: &OsString, vendor: &Path, target: &str, out_dir: &Path) -> PathBuf {
    let prefix = out_dir.join("libghostty-vt");
    let cache = out_dir.join("zig-cache");
    let version = fs::read_to_string(vendor.join("VERSION"))
        .expect("failed to read vendored libghostty-vt VERSION");

    let status = Command::new(zig)
        .arg("build")
        .arg("--prefix")
        .arg(&prefix)
        .arg("--cache-dir")
        .arg(&cache)
        .arg("-Demit-lib-vt")
        .arg("-Doptimize=ReleaseFast")
        .arg("-Dcpu=baseline")
        .arg("-Dsimd=true")
        .arg(format!("-Dtarget={}", zig_target(target)))
        .arg(format!("-Dversion-string={}", version.trim()))
        .arg("-Demit-xcframework=false")
        .current_dir(vendor)
        .status()
        .expect("failed to execute Zig libghostty-vt build");
    assert!(status.success(), "Zig libghostty-vt build failed: {status}");

    prefix.join("lib/libghostty-vt.a")
}

fn generate_bindings(vendor: &Path, out_dir: &Path, host: &str) {
    let include_dir = vendor.join("include");
    let header = include_dir.join("ghostty/vt.h");
    let bindings = bindgen::Builder::default()
        .header(header.to_string_lossy())
        .clang_arg(format!("-I{}", include_dir.display()))
        // Bindgen runs on the host. The public header is target-neutral and
        // both supported target families have a 64-bit size_t.
        .clang_arg(format!("--target={host}"))
        .allowlist_function("ghostty_.*")
        .allowlist_type("Ghostty.*")
        .allowlist_var(".*GHOSTTY.*")
        .derive_default(true)
        .generate_comments(false)
        .layout_tests(false)
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .generate()
        .expect("failed to bindgen include/ghostty/vt.h");

    bindings
        .write_to_file(out_dir.join("bindings.rs"))
        .expect("failed to write generated bindings");
}

fn main() {
    let manifest_dir = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let vendor = manifest_dir.join("vendor/libghostty-vt");
    let host = env::var("HOST").expect("Cargo did not set HOST");
    let target = env::var("TARGET").expect("Cargo did not set TARGET");
    let zig = env::var_os("ZIG").unwrap_or_else(|| OsString::from("zig"));

    println!("cargo:rerun-if-env-changed=ZIG");
    println!("cargo:rerun-if-env-changed=LIBCLANG_PATH");
    println!("cargo:rerun-if-env-changed=DEVELOPER_DIR");
    println!("cargo:rerun-if-changed=vendor/libghostty-vt.vendor.json");
    println!("cargo:rerun-if-changed=vendor/libghostty-vt/VERSION");
    println!("cargo:rerun-if-changed=vendor/libghostty-vt/build.zig");
    println!("cargo:rerun-if-changed=vendor/libghostty-vt/build.zig.zon");
    println!("cargo:rerun-if-changed=vendor/libghostty-vt/include");
    println!("cargo:rerun-if-changed=vendor/libghostty-vt/pkg");
    println!("cargo:rerun-if-changed=vendor/libghostty-vt/src");

    check_zig_version(&zig);
    let static_lib = build_libghostty(&zig, &vendor, &target, &out_dir);
    generate_bindings(&vendor, &out_dir, &host);

    // Unlike the standalone Phase 0 binary, this crate is a library
    // dependency. Cargo's native-link metadata must propagate the archive to
    // the final termiod link, so a Darwin-only `rustc-link-arg` is insufficient.
    println!(
        "cargo:rustc-link-search=native={}",
        static_lib.parent().unwrap().display()
    );
    println!("cargo:rustc-link-lib=static=ghostty-vt");
}
