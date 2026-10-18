//! Embeds the application manifest (requireAdministrator, per-monitor DPI) into
//! the Windows binary so the UAC elevation happens at launch. Only runs for
//! Windows targets; a no-op everywhere else so the interop build on macOS is
//! unaffected.
//!
//! The manifest is embedded only when the `require-admin` feature is on. The
//! no-elevation test build (`--no-default-features`) skips it so it runs without
//! a UAC prompt, which is needed to launch it over an unelevated AnyDesk session
//! where a prompt would land on the invisible secure desktop.
//!
//! The manifest is referenced from a minimal `.rc` as resource type 24
//! (`RT_MANIFEST`), id 1 (`CREATEPROCESS_MANIFEST_RESOURCE_ID`), which is what
//! Windows reads at launch. It is compiled with the toolchain's `windres`
//! (`rc.exe` is the MSVC equivalent): `embed-manifest` would be tidier but pulls
//! a dependency, and `windres` already ships with the mingw cross-toolchain.
//!
//! A missing `windres` does not fail the build: the binary still runs, it just
//! will not auto-elevate, and a loud warning keeps that from being a silent gap.
fn main() {
    let target = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target != "windows" {
        return;
    }
    if std::env::var("CARGO_FEATURE_REQUIRE_ADMIN").is_err() {
        println!("cargo:warning=building WITHOUT the requireAdministrator manifest (no-elevation build)");
        return;
    }
    println!("cargo:rerun-if-changed=rc-host.exe.manifest");


    let out_dir = std::env::var("OUT_DIR").unwrap();
    let rc_path = std::path::Path::new(&out_dir).join("rc-host.rc");
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("rc-host.exe.manifest");
    std::fs::write(
        &rc_path,
        format!("1 24 \"{}\"\n", manifest.display().to_string().replace('\\', "\\\\")),
    )
    .expect("write rc");


    let windres = std::env::var("RC_WINDRES").unwrap_or_else(|_| "x86_64-w64-mingw32-windres".into());
    let obj_path = std::path::Path::new(&out_dir).join("rc-host-manifest.o");
    let status = std::process::Command::new(&windres)
        .arg(&rc_path)
        .arg("-O")
        .arg("coff")
        .arg("-o")
        .arg(&obj_path)
        .status();
    match status {
        Ok(s) if s.success() => {
            println!("cargo:rustc-link-arg-bins={}", obj_path.display());
        }
        _ => {
            println!(
                "cargo:warning=could not run {windres}; the manifest was NOT embedded and the \
                 host will not auto-elevate. Install mingw-w64 or set RC_WINDRES."
            );
        }
    }
}
