fn main() -> std::process::ExitCode {
    match audioboost::run() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("audioboost: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}
