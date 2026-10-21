use crate::{
    Result,
    control::{Command, Gain, Reply, Request, Status},
    engine::{Engine, wait_events},
    ipc, terminal,
};
use std::{
    io::{self, IsTerminal},
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

static INTERRUPTED: AtomicBool = AtomicBool::new(false);
extern "C" fn on_signal(_: libc::c_int) {
    INTERRUPTED.store(true, Ordering::Relaxed);
}
pub(crate) fn interrupted() -> bool {
    INTERRUPTED.load(Ordering::Relaxed)
}

fn install_signals() -> Result<()> {
    for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        // SAFETY: handler only stores to a lock-free atomic; its lifetime is static.
        if unsafe { libc::signal(signal, on_signal as libc::sighandler_t) } == libc::SIG_ERR {
            return Err(io::Error::last_os_error().into());
        }
    }
    Ok(())
}

const HELP: &str = "AudioBoost — macOS audio booster\n\nUsage:\n  audioboost                       Enable boosting and open keyboard controls\n  audioboost start [--gain-db N]    Run in the background (default +3 dB)\n  audioboost gain N                 Set gain, 0–12 dB\n  audioboost status                 Show the current state\n  audioboost stop                   Restore normal playback\n\nControls: Up/Right +1 dB, Down/Left -1 dB; Q or Ctrl-C stops boosting and exits.\n";

/// Run the command-line application. Errors are reported by the binary entry point.
pub fn run() -> Result<()> {
    let command = Command::parse(&std::env::args().skip(1).collect::<Vec<_>>())?;
    if command == Command::Help {
        print!("{HELP}");
        return Ok(());
    }
    if command == Command::Interactive
        && (!io::stdin().is_terminal() || !io::stdout().is_terminal())
    {
        return Err("audioboost requires an interactive terminal; use 'audioboost start', 'gain', 'status', or 'stop' for scripting".into());
    }
    install_signals()?;
    let dir = ipc::runtime_dir()?;
    match command {
        Command::Serve => serve(&dir),
        Command::Start(gain) => {
            ensure_service(&dir)?;
            print_status(&ipc::request(&dir, &Request::Start(gain))?.status);
            Ok(())
        }
        Command::Interactive => {
            ensure_service(&dir)?;
            let result = (|| {
                let status = ipc::request(&dir, &Request::Start(Gain::default()))?.status;
                terminal::run(&dir, status)
            })();
            let stopped = stop(&dir);
            result.and(stopped)
        }
        Command::Gain(gain) => {
            print_status(&ipc::request(&dir, &Request::Gain(gain))?.status);
            Ok(())
        }
        Command::Status => {
            match ipc::request(&dir, &Request::Status) {
                Ok(reply) => print_status(&reply.status),
                Err(error) if absent(error.as_ref()) => print_status(&Status::default()),
                Err(error) => return Err(error),
            }
            Ok(())
        }
        Command::Stop => {
            stop(&dir)?;
            println!("AudioBoost stopped; normal playback restored");
            Ok(())
        }
        Command::Help => Ok(()),
    }
}

fn absent(error: &(dyn std::error::Error + 'static)) -> bool {
    error.downcast_ref::<io::Error>().is_some_and(|error| {
        matches!(
            error.kind(),
            io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
        )
    })
}

fn stop(dir: &Path) -> Result<()> {
    match ipc::request(dir, &Request::Stop) {
        Ok(_) => Ok(()),
        Err(error) if absent(error.as_ref()) => Ok(()),
        Err(error) => Err(error),
    }
}

fn print_status(status: &Status) {
    println!(
        "State: {}\nGain: +{:.1} dB\nOutput: {}\nSample rate: {:.0} Hz\nReported pipeline latency: {}\nPlayback buffer: {}\nCallbacks: {}\nFaults: {}\nPID: {}",
        status.state,
        status.gain_db,
        status.device,
        status.sample_rate,
        status.latency_text(),
        status.buffer_text(),
        status.callbacks,
        status.faults,
        status.pid
    );
    if !status.error.is_empty() {
        println!("Error: {}", status.error);
    }
}

fn bundle_path() -> Result<PathBuf> {
    let executable = std::env::current_exe()?.canonicalize()?;
    for parent in executable.ancestors() {
        if parent.extension().is_some_and(|ext| ext == "app") {
            return Ok(parent.to_path_buf());
        }
    }
    Err("run 'make install' and use the installed audioboost command; audio capture needs its signed app bundle".into())
}

fn ensure_service(dir: &Path) -> Result<()> {
    match ipc::request(dir, &Request::Status) {
        Ok(_) => return Ok(()),
        Err(error) if absent(error.as_ref()) => (),
        Err(error) => return Err(error),
    }
    let status = std::process::Command::new("/usr/bin/open")
        .args(["-g", "-j", "-n"])
        .arg(bundle_path()?)
        .args(["--args", "--serve"])
        .status()?;
    if !status.success() {
        return Err("LaunchServices could not start AudioBoost".into());
    }
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline && !interrupted() {
        match ipc::request(dir, &Request::Status) {
            Ok(_) => return Ok(()),
            Err(error) if absent(error.as_ref()) => std::thread::sleep(Duration::from_millis(50)),
            Err(error) => return Err(error),
        }
    }
    Err("AudioBoost service did not become ready; check Console for AudioBoost errors".into())
}

fn handle(engine: &mut Engine, request: Request) -> Reply {
    let result = match request {
        Request::Start(gain) => {
            if engine.status().state == "active" {
                Ok(())
            } else {
                engine.start(gain)
            }
        }
        Request::Gain(gain) => {
            if engine.status().state != "active" {
                Err("audio engine is not active".into())
            } else {
                engine.set_gain(gain);
                Ok(())
            }
        }
        Request::Adjust(delta) => {
            if ![-1, 1].contains(&delta) {
                Err("gain adjustment must be -1 or +1 dB".into())
            } else if engine.status().state != "active" {
                Err("audio engine is not active".into())
            } else {
                let gain =
                    Gain::new(engine.status().gain_db).map(|gain| gain.adjusted(f32::from(delta)));
                match gain {
                    Ok(gain) => {
                        engine.set_gain(gain);
                        Ok(())
                    }
                    Err(error) => Err(error.into()),
                }
            }
        }
        Request::Status => Ok(()),
        Request::Stop => unreachable!("stop is handled by the service owner"),
    };
    Reply {
        status: engine.status(),
        error: result
            .err()
            .map(|e: Box<dyn std::error::Error>| e.to_string()),
    }
}

fn serve(dir: &Path) -> Result<()> {
    let server = ipc::Server::bind(dir)?;
    let mut engine = Engine::new()?;
    while !interrupted() {
        engine.poll()?;
        match server.listener.accept() {
            Ok((mut stream, _)) => {
                if let Err(error) = ipc::configure_client(&stream) {
                    eprintln!("{error}");
                    continue;
                }
                let reply = match ipc::read_message::<Request>(&stream) {
                    Ok(Request::Stop) => {
                        let error = engine.stop().err().map(|error| error.to_string());
                        drop(engine);
                        ipc::write_message(
                            &mut stream,
                            &Reply {
                                status: Status::default(),
                                error,
                            },
                        )?;
                        return Ok(());
                    }
                    Ok(request) => handle(&mut engine, request),
                    Err(error) => Reply {
                        status: engine.status(),
                        error: Some(error.to_string()),
                    },
                };
                // A disconnected CLI must not terminate the audio service.
                if let Err(error) = ipc::write_message(&mut stream, &reply) {
                    eprintln!("control client: {error}");
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => wait_events(),
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}
