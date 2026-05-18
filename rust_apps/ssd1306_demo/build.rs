// build.rs: same shape as hello_rust/build.rs.  Points cargo at
// librp_asm.a (built by the top-level Makefile) and uses our SRAM linker.

use std::env;
use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let repo_root = manifest_dir.ancestors().nth(2).unwrap().to_path_buf();
    let build_dir = repo_root.join("build");
    let link_script = repo_root.join("link").join("sram.ld");

    println!("cargo:rerun-if-changed={}", build_dir.join("librp_asm.a").display());
    println!("cargo:rerun-if-changed={}", link_script.display());

    println!("cargo:rustc-link-search=native={}", build_dir.display());
    println!("cargo:rustc-link-lib=static=rp_asm");
    println!("cargo:rustc-link-arg=-T{}", link_script.display());
    println!("cargo:rustc-link-arg=-nostdlib");
    println!("cargo:rustc-link-arg=--gc-sections");
}
