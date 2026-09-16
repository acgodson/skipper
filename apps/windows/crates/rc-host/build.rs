// Embeds the application manifest (requireAdministrator, per-monitor DPI) into
// the Windows binary so the UAC elevation happens at launch. Only runs for
// Windows targets; a no-op everywhere else so the interop build on macOS is
// unaffected.
fn main() {
    let target = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target != "windows" {
        return;
    }
    // Only embed the elevation manifest when the require-admin feature is on.
    // The no-elevation test build (--no-default-features) skips it so it runs
    // without a UAC prompt — needed to launch it over an unelevated AnyDesk
    // session, where a UAC prompt would land on the invisible secure desktop.
    if std::env::var("CARGO_FEATURE_REQUIRE_ADMIN").is_err() {
        println!("cargo:warning=building WITHOUT the requireAdministrator manifest (no-elevation build)");
        return;
    }
    println!("cargo:rerun-if-changed=rc-host.exe.manifest");

    // A minimal .rc that references the manifest as resource type 24 (RT_MANIFEST),
    // id 1 (CREATEPROCESS_MANIFEST_RESOURCE_ID) — what Windows reads at launch.
    let out_dir = std::env::var("OUT_DIR").unwrap();
    let rc_path = std::path::Path::new(&out_dir).join("rc-host.rc");
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("rc-host.exe.manifest");
    std::fs::write(
        &rc_path,
        format!("1 24 \"{}\"\n", manifest.display().to_string().replace('\\', "\\\\")),
    )
    .expect("write rc");

    // Compile with the toolchain's windres. embed-manifest would be tidier but
    // pulls a dependency; windres ships with the mingw cross-toolchain already
    // in use, and with the MSVC toolchain rc.exe is the equivalent.
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
            // Do not fail the build if windres is missing: the binary still runs,
            // it just won't auto-elevate. Warn loudly so it is not a silent gap.
            println!(
                "cargo:warning=could not run {windres}; the manifest was NOT embedded and the \
                 host will not auto-elevate. Install mingw-w64 or set RC_WINDRES."
            );
        }
    }
}
