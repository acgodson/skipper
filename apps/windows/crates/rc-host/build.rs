//! Embeds the Windows resources: the SkipperDesk icon (the exe's icon, the
//! window's and the tray's) and the application manifest (per-monitor DPI).
//! Only runs for Windows targets; a no-op everywhere else so the interop build
//! on macOS is unaffected.
//!
//! The manifest is embedded only when the `require-admin` feature is on. The
//! no-elevation test build (`--no-default-features`) skips it so it runs without
//! a UAC prompt, which is needed to launch it over an unelevated AnyDesk session
//! where a prompt would land on the invisible secure desktop. The icon is
//! embedded either way.
//!
//! Both are referenced from a minimal `.rc`: the icon as `ICON` id 1, which the
//! window code loads by that id, and the manifest as resource type 24
//! (`RT_MANIFEST`), id 1 (`CREATEPROCESS_MANIFEST_RESOURCE_ID`), which is what
//! Windows reads at launch. It is compiled with the toolchain's `windres`
//! (`rc.exe` is the MSVC equivalent): `embed-manifest` would be tidier but pulls
//! a dependency, and `windres` already ships with the mingw cross-toolchain.
//! `resources/skipperdesk.ico` is made from the Mac app's iconset (16, 32, 48
//! and 256 px).
//!
//! A missing `windres` does not fail the build: the binary still runs, with the
//! stock application icon and without the manifest, and a loud warning keeps
//! that from being a silent gap.
fn main() {
    let target = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target != "windows" {
        return;
    }
    let crate_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let quoted = |path: std::path::PathBuf| format!("\"{}\"", path.display().to_string().replace('\\', "\\\\"));
    println!("cargo:rerun-if-changed=resources/skipperdesk.ico");
    let mut script = format!("1 ICON {}\n", quoted(crate_dir.join("resources").join("skipperdesk.ico")));
    match std::env::var("CARGO_FEATURE_REQUIRE_ADMIN") {
        Ok(_) => {
            println!("cargo:rerun-if-changed=rc-host.exe.manifest");
            script.push_str(&format!("1 24 {}\n", quoted(crate_dir.join("rc-host.exe.manifest"))));
        }
        Err(_) => {
            println!("cargo:warning=building WITHOUT the requireAdministrator manifest (no-elevation build)");
        }
    }

    let out_dir = std::env::var("OUT_DIR").unwrap();
    let rc_path = std::path::Path::new(&out_dir).join("rc-host.rc");
    std::fs::write(&rc_path, script).expect("write rc");

    let windres = std::env::var("RC_WINDRES").unwrap_or_else(|_| "x86_64-w64-mingw32-windres".into());
    let obj_path = std::path::Path::new(&out_dir).join("rc-host-resources.o");
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
                "cargo:warning=could not run {windres}; the icon and manifest were NOT embedded. \
                 Install mingw-w64 or set RC_WINDRES."
            );
        }
    }
}
