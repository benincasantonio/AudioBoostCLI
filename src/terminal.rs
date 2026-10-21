use crate::{
    Result,
    control::{Request, Status},
    ipc,
};
use crossterm::{
    cursor,
    event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers},
    execute,
    terminal::{self, Clear, ClearType, EnterAlternateScreen, LeaveAlternateScreen},
};
use std::{
    io::{self, Write},
    path::Path,
    time::{Duration, Instant},
};

#[derive(Debug, PartialEq)]
enum Action {
    Adjust(i8),
    Quit,
    None,
}

fn action(key: KeyEvent) -> Action {
    if key.kind == KeyEventKind::Release {
        return Action::None;
    }
    match key.code {
        KeyCode::Up | KeyCode::Right => Action::Adjust(1),
        KeyCode::Down | KeyCode::Left => Action::Adjust(-1),
        KeyCode::Char('q' | 'Q') => Action::Quit,
        KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => Action::Quit,
        _ => Action::None,
    }
}

struct Screen;
impl Screen {
    fn enter() -> Result<Self> {
        terminal::enable_raw_mode()?;
        let screen = Self;
        execute!(io::stdout(), EnterAlternateScreen, cursor::Hide)?;
        Ok(screen)
    }
}
impl Drop for Screen {
    fn drop(&mut self) {
        let _ = execute!(io::stdout(), cursor::Show, LeaveAlternateScreen);
        let _ = terminal::disable_raw_mode();
    }
}

fn render(status: &Status) -> Result<()> {
    let mut stdout = io::stdout().lock();
    execute!(stdout, cursor::MoveTo(0, 0), Clear(ClearType::All))?;
    // Strip control characters from device names and errors before rendering terminal text.
    let clean = |s: &str| s.chars().filter(|c| !c.is_control()).collect::<String>();
    write!(
        stdout,
        "AudioBoost\r\n\r\nGain: +{:.1} dB    State: {}\r\nOutput: {}\r\nSample rate: {:.0} Hz\r\n\r\nUp/Right +1 dB   Down/Left -1 dB\r\nQ or Ctrl-C: stop boosting and exit\r\n",
        status.gain_db,
        clean(&status.state),
        clean(&status.device),
        status.sample_rate
    )?;
    if !status.error.is_empty() {
        write!(stdout, "\r\n{}\r\n", clean(&status.error))?;
    }
    stdout.flush()?;
    Ok(())
}

pub(crate) fn run(dir: &Path, mut status: Status) -> Result<()> {
    let screen = Screen::enter()?;
    let result = (|| {
        render(&status)?;
        let mut last_poll = Instant::now();
        loop {
            if crate::app::interrupted() {
                break;
            }
            let timeout = Duration::from_millis(250).saturating_sub(last_poll.elapsed());
            if event::poll(timeout)? {
                match event::read()? {
                    Event::Key(key) => match action(key) {
                        Action::Quit => break,
                        Action::Adjust(delta) => {
                            let updated = ipc::request(dir, &Request::Adjust(delta))?.status;
                            if display_changed(&status, &updated) {
                                render(&updated)?;
                            }
                            status = updated;
                        }
                        Action::None => (),
                    },
                    Event::Resize(_, _) => render(&status)?,
                    _ => (),
                }
            }
            if last_poll.elapsed() >= Duration::from_millis(250) {
                let updated = ipc::request(dir, &Request::Status)?.status;
                if updated.state == "idle" || updated.state == "stopped" {
                    break;
                }
                if display_changed(&status, &updated) {
                    render(&updated)?;
                }
                status = updated;
                last_poll = Instant::now();
            }
        }
        Ok(())
    })();
    drop(screen);
    result
}

fn display_changed(previous: &Status, current: &Status) -> bool {
    previous.gain_db != current.gain_db
        || previous.device != current.device
        || previous.state != current.state
        || previous.error != current.error
        || previous.sample_rate != current.sample_rate
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn arrow_keys_and_quit_have_unambiguous_actions() {
        for code in [KeyCode::Up, KeyCode::Right] {
            assert_eq!(
                action(KeyEvent::new(code, KeyModifiers::NONE)),
                Action::Adjust(1)
            );
        }
        for code in [KeyCode::Down, KeyCode::Left] {
            assert_eq!(
                action(KeyEvent::new(code, KeyModifiers::NONE)),
                Action::Adjust(-1)
            );
        }
        assert_eq!(
            action(KeyEvent::new(KeyCode::Char('q'), KeyModifiers::NONE)),
            Action::Quit
        );
        assert_eq!(
            action(KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL)),
            Action::Quit
        );
        assert_eq!(
            action(KeyEvent::new(KeyCode::Char('c'), KeyModifiers::NONE)),
            Action::None
        );
    }
}
