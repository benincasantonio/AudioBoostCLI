fn main() {
    println!("cargo:rerun-if-changed=native");
    if std::env::var_os("CARGO_CFG_MIRI").is_some() {
        return;
    }
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        panic!("AudioBoostCLI supports macOS only");
    }
    cc::Build::new()
        .file("native/processor.c")
        .flag("-std=c11")
        .flag("-mmacosx-version-min=14.2")
        .warnings_into_errors(true)
        .compile("audio_processor");
    cc::Build::new()
        .file("native/engine.m")
        .flag("-std=c11")
        .flag("-fobjc-arc")
        .flag("-mmacosx-version-min=14.2")
        .warnings_into_errors(true)
        .compile("audio_engine");
    println!("cargo:rustc-link-lib=framework=AudioToolbox");
    println!("cargo:rustc-link-lib=framework=CoreAudio");
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=IOKit");
}
