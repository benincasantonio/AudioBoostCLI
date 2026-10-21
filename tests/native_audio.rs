#[test]
fn native_processor_contract() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let dir = root.join("target/native");
    std::fs::create_dir_all(&dir).unwrap();
    let executable = dir.join(format!("processor-test-{}", std::process::id()));
    let compilation = std::process::Command::new("xcrun")
        .current_dir(root)
        .args([
            "clang",
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "native/processor.c",
            "native/processor_test.c",
            "-framework",
            "AudioToolbox",
            "-o",
        ])
        .arg(&executable)
        .output()
        .unwrap();
    assert!(
        compilation.status.success(),
        "{}",
        String::from_utf8_lossy(&compilation.stderr)
    );
    let test = std::process::Command::new(&executable).output().unwrap();
    std::fs::remove_file(executable).unwrap();
    assert!(
        test.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&test.stdout),
        String::from_utf8_lossy(&test.stderr)
    );
}
