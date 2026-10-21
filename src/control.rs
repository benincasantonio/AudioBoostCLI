use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "f32", into = "f32")]
pub struct Gain(f32);

impl Gain {
    /// Construct a gain in decibels, rejecting nonfinite values and values outside 0..=12.
    pub fn new(db: f32) -> Result<Self, String> {
        if db.is_finite() && (0.0..=12.0).contains(&db) {
            Ok(Self(db))
        } else {
            Err("gain must be a finite number from 0 to 12 dB".into())
        }
    }
    pub fn db(self) -> f32 {
        self.0
    }
    pub fn amplitude(self) -> f32 {
        10.0_f32.powf(self.0 / 20.0)
    }
    pub fn adjusted(self, delta: f32) -> Self {
        if delta.is_finite() {
            Self((self.0 + delta).clamp(0.0, 12.0))
        } else {
            self
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) enum Request {
    Start(Gain),
    Gain(Gain),
    Adjust(i8),
    Status,
    Stop,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct Status {
    pub state: String,
    pub gain_db: f32,
    pub device: String,
    pub sample_rate: f64,
    pub latency_ms: f64,
    pub callbacks: u64,
    pub faults: u64,
    pub error: String,
    pub pid: u32,
}

impl Default for Status {
    fn default() -> Self {
        Self {
            state: "stopped".into(),
            gain_db: 0.0,
            device: String::new(),
            sample_rate: 0.0,
            latency_ms: 0.0,
            callbacks: 0,
            faults: 0,
            error: String::new(),
            pid: 0,
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub(crate) struct Reply {
    pub status: Status,
    pub error: Option<String>,
}

impl Default for Gain {
    fn default() -> Self {
        Self(3.0)
    }
}
impl TryFrom<f32> for Gain {
    type Error = String;
    fn try_from(value: f32) -> Result<Self, String> {
        Self::new(value)
    }
}
impl From<Gain> for f32 {
    fn from(value: Gain) -> Self {
        value.0
    }
}

#[derive(Debug, PartialEq)]
pub enum Command {
    Interactive,
    Start(Gain),
    Gain(Gain),
    Status,
    Stop,
    Help,
    Serve,
}

impl Command {
    pub fn parse(args: &[String]) -> Result<Self, String> {
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        let gain = |s: &str| {
            s.parse::<f32>()
                .map_err(|_| "gain must be a number".to_string())
                .and_then(Gain::new)
        };
        match args.as_slice() {
            [] => Ok(Self::Interactive),
            ["start"] => Ok(Self::Start(Gain::default())),
            ["start", "--gain-db", db] => Ok(Self::Start(gain(db)?)),
            ["gain", db] => Ok(Self::Gain(gain(db)?)),
            ["status"] => Ok(Self::Status),
            ["stop"] => Ok(Self::Stop),
            ["help" | "--help" | "-h"] => Ok(Self::Help),
            ["--serve"] => Ok(Self::Serve),
            _ => Err("invalid command; run audioboost --help".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<Command, String> {
        Command::parse(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn gain_rejects_nonfinite_and_out_of_range_values() {
        for db in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY, -0.01, 12.01] {
            assert!(Gain::new(db).is_err(), "accepted {db}");
        }
        for db in [0.0, 3.0, 6.5, 12.0] {
            assert_eq!(Gain::new(db).unwrap().db(), db);
        }
    }
    #[test]
    fn gain_amplitude_uses_decibels() {
        assert_eq!(Gain::new(0.0).unwrap().amplitude(), 1.0);
        assert!((Gain::new(6.0).unwrap().amplitude() - 1.9952623).abs() < 1e-6);
    }
    #[test]
    fn arrow_adjustments_clamp_at_both_boundaries() {
        assert_eq!(Gain::new(11.5).unwrap().adjusted(1.0).db(), 12.0);
        assert_eq!(Gain::new(0.5).unwrap().adjusted(-1.0).db(), 0.0);
        assert_eq!(Gain::default().adjusted(1.0).db(), 4.0);
    }
    #[test]
    fn default_is_interactive_and_start_has_three_db_default() {
        assert_eq!(parse(&[]).unwrap(), Command::Interactive);
        assert_eq!(parse(&["start"]).unwrap(), Command::Start(Gain::default()));
        assert_eq!(
            parse(&["start", "--gain-db", "6.5"]).unwrap(),
            Command::Start(Gain::new(6.5).unwrap())
        );
    }
    #[test]
    fn commands_reject_typos_missing_values_and_extra_arguments() {
        for args in [
            vec!["gain"],
            vec!["gain", "NaN"],
            vec!["start", "--gain", "3"],
            vec!["stop", "now"],
            vec!["wat"],
        ] {
            assert!(parse(&args).is_err(), "accepted {args:?}");
        }
        assert_eq!(
            parse(&["gain", "6"]).unwrap(),
            Command::Gain(Gain::new(6.0).unwrap())
        );
        assert_eq!(parse(&["status"]).unwrap(), Command::Status);
        assert_eq!(parse(&["stop"]).unwrap(), Command::Stop);
    }
    #[test]
    fn deserialization_cannot_bypass_gain_validation() {
        assert!(serde_json::from_str::<Gain>("13").is_err());
        assert_eq!(serde_json::from_str::<Gain>("4.5").unwrap().db(), 4.5);
    }
}
