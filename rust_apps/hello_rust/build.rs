// build.rs — points cargo at librp_asm.a (built by the top-level Makefile)
// and feeds it our SRAM linker script.

use std::env;
use std::path::PathBuf;

fn main() {
    // Locate repo root (../.. from this app dir).
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let repo_root = manifest_dir
        .ancestors()
        .nth(2)
        .expect("expected rust_apps/<name>/ to be 2 levels under repo root")
        .to_path_buf();
    let build_dir = repo_root.join("build");
    let link_script = repo_root.join("link").join("sram.ld");

    // The Makefile target rust-apps depends on build/librp_asm.a, but cargo
    // can also be invoked directly.  Emit a rerun hint so changes to the
    // archive trigger a relink.
    println!(
        "cargo:rerun-if-changed={}",
        build_dir.join("librp_asm.a").display()
    );
    println!("cargo:rerun-if-changed={}", link_script.display());

    println!("cargo:rustc-link-search=native={}", build_dir.display());
    println!("cargo:rustc-link-lib=static=rp_asm");
    println!("cargo:rustc-link-arg=-T{}", link_script.display());
    println!("cargo:rustc-link-arg=-nostdlib");
    println!("cargo:rustc-link-arg=--gc-sections");
}
