use std::process::Command;

#[test]
fn no_arguments_requires_a_terminal_without_starting_audio() {
    let output = Command::new(env!("CARGO_BIN_EXE_audioboost"))
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("interactive terminal"));
}

#[test]
fn help_lists_interactive_keys_and_script_commands() {
    let output = Command::new(env!("CARGO_BIN_EXE_audioboost"))
        .arg("--help")
        .output()
        .unwrap();
    assert!(output.status.success());
    let help = String::from_utf8(output.stdout).unwrap();
    for expected in ["start", "gain", "status", "stop", "Ctrl-C"] {
        assert!(help.contains(expected));
    }
}

#[test]
fn malformed_gain_is_rejected_before_connecting_to_a_service() {
    for gain in ["NaN", "inf", "-1", "13", "nope"] {
        let output = Command::new(env!("CARGO_BIN_EXE_audioboost"))
            .args(["gain", gain])
            .output()
            .unwrap();
        assert!(!output.status.success());
        assert!(String::from_utf8_lossy(&output.stderr).contains("gain"));
    }
}
