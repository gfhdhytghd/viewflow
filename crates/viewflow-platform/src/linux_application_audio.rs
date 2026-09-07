//! Linux PulseAudio-compatible implementation of the application-audio control
//! boundary.
//!
//! `PipeWire`'s `PulseAudio` compatibility service accepts these `pactl` commands.
//! The adapter creates a `module-null-sink` for one Viewflow route, moves only
//! a caller-selected sink input, and later restores that exact input.  It never
//! calls `set-default-sink`, writes default-node metadata, lists/records a
//! general host monitor, or creates a whole-system loopback.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::io::{self, Read};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

#[cfg(test)]
use std::collections::VecDeque;

use crate::application_audio::ApplicationAudioControl;

const DEFAULT_COMMAND_TIMEOUT: Duration = Duration::from_secs(2);
const COMMAND_POLL_INTERVAL: Duration = Duration::from_millis(10);
const WORKER_REAP_TIMEOUT: Duration = Duration::from_millis(100);
const MAX_PACTL_OUTPUT_BYTES: usize = 4 * 1024 * 1024;
const MAX_PACTL_STDERR_BYTES: usize = 64 * 1024;

/// Minimal process boundary for `pactl`.  Tests inject a recording runner so
/// no user audio server is queried or modified during unit tests.
pub trait PactlCommandRunner {
    type Error;

    /// Runs `pactl` with exact argv (without the program name) and returns
    /// stdout only when the command exits successfully.
    ///
    /// # Errors
    ///
    /// Returns the runner-specific error when the exact argv fails or times
    /// out before producing a bounded stdout result.
    fn run_pactl(&mut self, args: &[String]) -> Result<String, Self::Error>;
}

/// Process-backed runner for the explicit runtime owner to opt into.  Merely
/// constructing this type performs no audio-server operation.
#[derive(Clone, Debug)]
pub struct ProcessPactlRunner {
    program: String,
    command_timeout: Duration,
}

impl Default for ProcessPactlRunner {
    fn default() -> Self {
        Self {
            program: "pactl".to_owned(),
            command_timeout: DEFAULT_COMMAND_TIMEOUT,
        }
    }
}

impl ProcessPactlRunner {
    #[must_use]
    pub fn new(program: impl Into<String>) -> Self {
        Self {
            program: program.into(),
            command_timeout: DEFAULT_COMMAND_TIMEOUT,
        }
    }

    /// Sets a finite child-process budget. A zero duration fails immediately,
    /// after the spawned child has been killed and reaped.
    #[must_use]
    pub fn with_timeout(mut self, command_timeout: Duration) -> Self {
        self.command_timeout = command_timeout;
        self
    }
}

#[derive(Debug)]
pub enum ProcessPactlError {
    Io(io::Error),
    Failed { status: Option<i32>, stderr: String },
    TimedOut,
    OutputTooLarge,
    InvalidUtf8,
}

impl fmt::Display for ProcessPactlError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "could not execute pactl: {error}"),
            Self::Failed { status, stderr } => write!(
                formatter,
                "pactl exited with {:?}: {}",
                status,
                stderr.trim()
            ),
            Self::TimedOut => formatter.write_str("pactl exceeded its command timeout"),
            Self::OutputTooLarge => formatter.write_str("pactl output exceeded the bounded limit"),
            Self::InvalidUtf8 => formatter.write_str("pactl returned non-UTF-8 output"),
        }
    }
}

impl std::error::Error for ProcessPactlError {}

impl PactlCommandRunner for ProcessPactlRunner {
    type Error = ProcessPactlError;

    fn run_pactl(&mut self, args: &[String]) -> Result<String, Self::Error> {
        let mut child = Command::new(&self.program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(ProcessPactlError::Io)?;
        let stdout = child.stdout.take().ok_or_else(|| {
            stop_child(&mut child);
            ProcessPactlError::Io(io::Error::other("pactl stdout pipe was unavailable"))
        })?;
        let stderr = child.stderr.take().ok_or_else(|| {
            stop_child(&mut child);
            ProcessPactlError::Io(io::Error::other("pactl stderr pipe was unavailable"))
        })?;
        let stdout_receiver = read_bounded_async(stdout, MAX_PACTL_OUTPUT_BYTES);
        let stderr_receiver = read_bounded_async(stderr, MAX_PACTL_STDERR_BYTES);
        let deadline = Instant::now() + self.command_timeout;

        loop {
            let status = child.try_wait().map_err(|error| {
                stop_child(&mut child);
                ProcessPactlError::Io(error)
            })?;
            if let Some(status) = status {
                let stdout = receive_pipe(&stdout_receiver)?;
                let stderr = receive_pipe(&stderr_receiver)?;
                if stdout.len() > MAX_PACTL_OUTPUT_BYTES || stderr.len() > MAX_PACTL_STDERR_BYTES {
                    return Err(ProcessPactlError::OutputTooLarge);
                }
                if !status.success() {
                    return Err(ProcessPactlError::Failed {
                        status: status.code(),
                        stderr: String::from_utf8_lossy(&stderr).into_owned(),
                    });
                }
                return String::from_utf8(stdout).map_err(|_| ProcessPactlError::InvalidUtf8);
            }
            if Instant::now() >= deadline {
                stop_child(&mut child);
                let _ = stdout_receiver.recv_timeout(WORKER_REAP_TIMEOUT);
                let _ = stderr_receiver.recv_timeout(WORKER_REAP_TIMEOUT);
                return Err(ProcessPactlError::TimedOut);
            }
            thread::sleep(COMMAND_POLL_INTERVAL);
        }
    }
}

fn read_bounded_async<R>(
    reader: R,
    maximum_bytes: usize,
) -> mpsc::Receiver<Result<Vec<u8>, io::Error>>
where
    R: Read + Send + 'static,
{
    let (sender, receiver) = mpsc::sync_channel(1);
    thread::spawn(move || {
        let mut output = Vec::with_capacity(maximum_bytes.min(64 * 1024));
        let result = reader
            .take((maximum_bytes as u64).saturating_add(1))
            .read_to_end(&mut output)
            .map(|_| output);
        let _ = sender.send(result);
    });
    receiver
}

fn receive_pipe(
    receiver: &mpsc::Receiver<Result<Vec<u8>, io::Error>>,
) -> Result<Vec<u8>, ProcessPactlError> {
    receiver
        .recv_timeout(WORKER_REAP_TIMEOUT)
        .map_err(|_| ProcessPactlError::Io(io::Error::other("pactl pipe worker did not exit")))?
        .map_err(ProcessPactlError::Io)
}

fn stop_child(child: &mut std::process::Child) {
    let _ = child.kill();
    let _ = child.wait();
}

/*
 * `pactl` does not expose `get-sink-input-info`/`get-sink-info` in the
 * installed CLI. The adapter intentionally resolves identities through its
 * documented JSON list surface instead of depending on an invented command.
 */

#[derive(Debug)]
pub enum LinuxApplicationAudioError<E> {
    Command(E),
    InvalidPrivateSinkId,
    DuplicatePrivateSink,
    UnknownPrivateSink,
    PrivateSinkUncertain,
    InvalidNativeInputId,
    InvalidSinkName,
    UnobservedRestoreSink,
    InvalidModuleId,
    InvalidJson,
    SinkInputNotFound,
    SinkNotFound,
}

impl<E: fmt::Display> fmt::Display for LinuxApplicationAudioError<E> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Command(error) => write!(formatter, "pactl command failed: {error}"),
            Self::InvalidPrivateSinkId => {
                formatter.write_str("private Viewflow sink id is invalid")
            }
            Self::DuplicatePrivateSink => {
                formatter.write_str("private Viewflow sink already exists")
            }
            Self::UnknownPrivateSink => {
                formatter.write_str("private Viewflow sink is not owned by this adapter")
            }
            Self::PrivateSinkUncertain => formatter.write_str(
                "private Viewflow sink may exist but its module identity was not confirmed; manual reconciliation is required",
            ),
            Self::InvalidNativeInputId => {
                formatter.write_str("PulseAudio sink-input id is invalid")
            }
            Self::InvalidSinkName => formatter.write_str("PulseAudio sink name is invalid"),
            Self::UnobservedRestoreSink => formatter.write_str(
                "refusing to move to a sink not observed as this input's restore target",
            ),
            Self::InvalidModuleId => formatter.write_str("pactl returned an invalid module id"),
            Self::InvalidJson => formatter.write_str("pactl returned invalid JSON"),
            Self::SinkInputNotFound => formatter.write_str("pactl did not list the selected sink input"),
            Self::SinkNotFound => formatter.write_str("pactl did not list the selected sink"),
        }
    }
}

impl<E: fmt::Debug + fmt::Display> std::error::Error for LinuxApplicationAudioError<E> {}

/// Concrete Linux implementation.  The owned-module map ensures it unloads
/// only private sinks created by this instance, while the observed restore set
/// ensures a restore move cannot become an arbitrary output-device selection.
#[derive(Debug)]
pub struct PactlApplicationAudioControl<R> {
    runner: R,
    owned_modules: BTreeMap<String, String>,
    unresolved_private_sinks: BTreeSet<String>,
    observed_restore_sinks: BTreeSet<String>,
}

impl<R> PactlApplicationAudioControl<R>
where
    R: PactlCommandRunner,
{
    #[must_use]
    pub fn new(runner: R) -> Self {
        Self {
            runner,
            owned_modules: BTreeMap::new(),
            unresolved_private_sinks: BTreeSet::new(),
            observed_restore_sinks: BTreeSet::new(),
        }
    }

    #[must_use]
    pub fn runner(&self) -> &R {
        &self.runner
    }

    #[must_use]
    pub fn owned_private_sink(&self, sink_id: &str) -> bool {
        self.owned_modules.contains_key(sink_id)
    }

    /// A successful module load with malformed stdout cannot safely be undone
    /// because guessing a module number could unload somebody else's module.
    /// These names stay fenced until an operator performs explicit native
    /// reconciliation.
    #[must_use]
    pub fn private_sink_is_unresolved(&self, sink_id: &str) -> bool {
        self.unresolved_private_sinks.contains(sink_id)
    }

    fn invoke(&mut self, args: &[String]) -> Result<String, LinuxApplicationAudioError<R::Error>> {
        self.runner
            .run_pactl(args)
            .map_err(LinuxApplicationAudioError::Command)
    }
}

impl<R> ApplicationAudioControl for PactlApplicationAudioControl<R>
where
    R: PactlCommandRunner,
{
    type Error = LinuxApplicationAudioError<R::Error>;

    fn create_viewflow_sink(&mut self, sink_id: &str) -> Result<(), Self::Error> {
        if !is_private_viewflow_sink_id(sink_id) {
            return Err(LinuxApplicationAudioError::InvalidPrivateSinkId);
        }
        if self.owned_modules.contains_key(sink_id) {
            return Err(LinuxApplicationAudioError::DuplicatePrivateSink);
        }
        if self.unresolved_private_sinks.contains(sink_id) {
            return Err(LinuxApplicationAudioError::PrivateSinkUncertain);
        }
        // One argv element per module argument avoids shell expansion.  The
        // module is deliberately private to the route and never becomes the
        // host's default sink.
        let output = self.invoke(&[
            "load-module".to_owned(),
            "module-null-sink".to_owned(),
            format!("sink_name={sink_id}"),
            "sink_properties=device.description=Viewflow_per_application_capture".to_owned(),
        ])?;
        let module_id = match parse_module_id(&output) {
            Ok(module_id) => module_id,
            Err(error) => {
                self.unresolved_private_sinks.insert(sink_id.to_owned());
                return Err(error);
            }
        };
        self.owned_modules.insert(sink_id.to_owned(), module_id);
        Ok(())
    }

    fn destroy_viewflow_sink(&mut self, sink_id: &str) -> Result<(), Self::Error> {
        if self.unresolved_private_sinks.contains(sink_id) {
            return Err(LinuxApplicationAudioError::PrivateSinkUncertain);
        }
        let Some(module_id) = self.owned_modules.get(sink_id).cloned() else {
            return Err(LinuxApplicationAudioError::UnknownPrivateSink);
        };
        self.invoke(&["unload-module".to_owned(), module_id])?;
        self.owned_modules.remove(sink_id);
        self.observed_restore_sinks.remove(sink_id);
        Ok(())
    }

    fn current_sink(&mut self, native_input_id: &str) -> Result<String, Self::Error> {
        validate_native_input_id(native_input_id)?;
        let inputs = self.invoke(&[
            "--format=json".to_owned(),
            "list".to_owned(),
            "sink-inputs".to_owned(),
        ])?;
        let sink_index = sink_for_input(&inputs, native_input_id)?;
        let sinks = self.invoke(&[
            "--format=json".to_owned(),
            "list".to_owned(),
            "sinks".to_owned(),
        ])?;
        let sink_name = sink_name_for_index(&sinks, sink_index)?;
        self.observed_restore_sinks.insert(sink_name.clone());
        Ok(sink_name)
    }

    fn move_input_to_sink(
        &mut self,
        native_input_id: &str,
        sink_id: &str,
    ) -> Result<(), Self::Error> {
        validate_native_input_id(native_input_id)?;
        validate_sink_name(sink_id)?;
        if !self.owned_modules.contains_key(sink_id)
            && !self.observed_restore_sinks.contains(sink_id)
        {
            return Err(LinuxApplicationAudioError::UnobservedRestoreSink);
        }
        self.invoke(&[
            "move-sink-input".to_owned(),
            native_input_id.to_owned(),
            sink_id.to_owned(),
        ])?;
        Ok(())
    }
}

fn sink_for_input<E>(
    output: &str,
    native_input_id: &str,
) -> Result<u64, LinuxApplicationAudioError<E>> {
    let requested = native_input_id
        .parse::<u64>()
        .map_err(|_| LinuxApplicationAudioError::InvalidNativeInputId)?;
    let entries: serde_json::Value =
        serde_json::from_str(output).map_err(|_| LinuxApplicationAudioError::InvalidJson)?;
    let entries = entries
        .as_array()
        .ok_or(LinuxApplicationAudioError::InvalidJson)?;
    entries
        .iter()
        .find(|entry| entry.get("index").and_then(serde_json::Value::as_u64) == Some(requested))
        .and_then(|entry| entry.get("sink").and_then(serde_json::Value::as_u64))
        .ok_or(LinuxApplicationAudioError::SinkInputNotFound)
}

fn sink_name_for_index<E>(
    output: &str,
    sink_index: u64,
) -> Result<String, LinuxApplicationAudioError<E>> {
    let entries: serde_json::Value =
        serde_json::from_str(output).map_err(|_| LinuxApplicationAudioError::InvalidJson)?;
    let entries = entries
        .as_array()
        .ok_or(LinuxApplicationAudioError::InvalidJson)?;
    let sink_name = entries
        .iter()
        .find(|entry| entry.get("index").and_then(serde_json::Value::as_u64) == Some(sink_index))
        .and_then(|entry| entry.get("name").and_then(serde_json::Value::as_str))
        .ok_or(LinuxApplicationAudioError::SinkNotFound)?;
    validate_sink_name(sink_name)?;
    Ok(sink_name.to_owned())
}

fn parse_module_id<E>(output: &str) -> Result<String, LinuxApplicationAudioError<E>> {
    let trimmed = output.trim();
    if trimmed.is_empty()
        || trimmed.contains(char::is_whitespace)
        || !trimmed.bytes().all(|byte| byte.is_ascii_digit())
        || trimmed.parse::<u32>().is_err()
    {
        return Err(LinuxApplicationAudioError::InvalidModuleId);
    }
    Ok(trimmed.to_owned())
}

fn validate_native_input_id<E>(value: &str) -> Result<(), LinuxApplicationAudioError<E>> {
    if value.is_empty()
        || !value.bytes().all(|byte| byte.is_ascii_digit())
        || value.parse::<u32>().is_err()
    {
        return Err(LinuxApplicationAudioError::InvalidNativeInputId);
    }
    Ok(())
}

fn validate_sink_name<E>(value: &str) -> Result<(), LinuxApplicationAudioError<E>> {
    if value.is_empty()
        || value.len() > 255
        || value.chars().any(char::is_control)
        || value.chars().any(char::is_whitespace)
    {
        return Err(LinuxApplicationAudioError::InvalidSinkName);
    }
    Ok(())
}

fn is_private_viewflow_sink_id(value: &str) -> bool {
    value.starts_with("viewflow.family.")
        && value.len() <= 255
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'.')
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application_audio::{ApplicationAudioRuntime, RegisteredApplicationInput};
    use viewflow_protocol::{AudioRoute, Id128, Point, Rect, Size, WindowDescriptor, WindowRole};

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct FakePactlError;

    impl fmt::Display for FakePactlError {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter.write_str("fake pactl failure")
        }
    }

    #[derive(Debug, Default)]
    struct RecordingPactl {
        calls: Vec<Vec<String>>,
        responses: VecDeque<Result<String, FakePactlError>>,
    }

    impl RecordingPactl {
        fn with_responses(responses: impl IntoIterator<Item = &'static str>) -> Self {
            Self {
                calls: Vec::new(),
                responses: responses
                    .into_iter()
                    .map(|response| Ok(response.to_owned()))
                    .collect(),
            }
        }
    }

    impl PactlCommandRunner for RecordingPactl {
        type Error = FakePactlError;

        fn run_pactl(&mut self, args: &[String]) -> Result<String, Self::Error> {
            self.calls.push(args.to_vec());
            self.responses.pop_front().unwrap_or(Err(FakePactlError))
        }
    }

    fn window() -> WindowDescriptor {
        WindowDescriptor {
            id: Id128(30),
            family_id: Id128(50),
            source_device: Id128(1),
            role: WindowRole::Main,
            bounds_dip: Rect {
                origin: Point::default(),
                size: Size {
                    width: 500.0,
                    height: 400.0,
                },
            },
            min_size_dip: Size::default(),
            max_size_dip: None,
            has_alpha: false,
            blur_radius_dip: None,
        }
    }

    fn route(generation: u64, enabled: bool) -> AudioRoute {
        AudioRoute {
            generation,
            family_id: Id128(50),
            source_device: Id128(1),
            target_device: Id128(2),
            target_output_id: "receiver-headphones".to_owned(),
            enabled,
        }
    }

    #[test]
    fn route_lifecycle_uses_only_private_sink_input_commands() {
        // apply: load module, resolve input sink index/name, move input.
        // revoke: resolve private sink index/name, restore input, unload module.
        let runner = RecordingPactl::with_responses([
            "42\n",
            "[{\"index\":7,\"sink\":5}]\n",
            "[{\"index\":5,\"name\":\"host-speakers\"}]\n",
            "",
            "[{\"index\":7,\"sink\":42}]\n",
            "[{\"index\":42,\"name\":\"viewflow.family.00000000000000000000000000000032.generation.00000000000000000001\"}]\n",
            "",
            "",
        ]);
        let control = PactlApplicationAudioControl::new(runner);
        let mut runtime = ApplicationAudioRuntime::new(Id128(1), control);
        runtime
            .register_input(RegisteredApplicationInput {
                native_input_id: "7".to_owned(),
                window: window(),
            })
            .unwrap();
        runtime.apply_route(route(1, true)).unwrap();
        runtime.apply_route(route(2, false)).unwrap();

        let calls = &runtime.control().runner().calls;
        let sink =
            "viewflow.family.00000000000000000000000000000032.generation.00000000000000000001";
        assert_eq!(
            calls,
            &vec![
                vec![
                    "load-module".to_owned(),
                    "module-null-sink".to_owned(),
                    format!("sink_name={sink}"),
                    "sink_properties=device.description=Viewflow_per_application_capture"
                        .to_owned(),
                ],
                vec![
                    "--format=json".to_owned(),
                    "list".to_owned(),
                    "sink-inputs".to_owned(),
                ],
                vec![
                    "--format=json".to_owned(),
                    "list".to_owned(),
                    "sinks".to_owned(),
                ],
                vec![
                    "move-sink-input".to_owned(),
                    "7".to_owned(),
                    sink.to_owned()
                ],
                vec![
                    "--format=json".to_owned(),
                    "list".to_owned(),
                    "sink-inputs".to_owned(),
                ],
                vec![
                    "--format=json".to_owned(),
                    "list".to_owned(),
                    "sinks".to_owned(),
                ],
                vec![
                    "move-sink-input".to_owned(),
                    "7".to_owned(),
                    "host-speakers".to_owned()
                ],
                vec!["unload-module".to_owned(), "42".to_owned()],
            ]
        );
        assert!(calls.iter().all(|argv| {
            !argv.iter().any(|argument| {
                argument == "set-default-sink"
                    || argument == "set-default-source"
                    || argument.contains("default.node")
                    || argument == "load-module module-loopback"
            })
        }));
    }

    #[test]
    fn adapter_refuses_unknown_sink_and_never_runs_a_command() {
        let mut control = PactlApplicationAudioControl::new(RecordingPactl::default());
        assert!(matches!(
            control.move_input_to_sink("7", "arbitrary-host-sink"),
            Err(LinuxApplicationAudioError::UnobservedRestoreSink)
        ));
        assert!(control.runner().calls.is_empty());
    }

    #[test]
    fn parser_rejects_ambiguous_or_unsafe_pactl_output() {
        assert!(parse_module_id::<FakePactlError>("42\nextra").is_err());
        assert!(parse_module_id::<FakePactlError>("shell;42\n").is_err());
        assert!(matches!(
            validate_native_input_id::<FakePactlError>("7;8"),
            Err(LinuxApplicationAudioError::InvalidNativeInputId)
        ));
        assert!(matches!(
            validate_sink_name::<FakePactlError>("host speakers"),
            Err(LinuxApplicationAudioError::InvalidSinkName)
        ));
    }

    #[test]
    fn malformed_successful_load_fences_the_private_sink_without_guessing_an_unload() {
        let runner = RecordingPactl::with_responses(["not-a-module-id\n"]);
        let mut control = PactlApplicationAudioControl::new(runner);
        let sink =
            "viewflow.family.00000000000000000000000000000032.generation.00000000000000000001";
        assert!(matches!(
            control.create_viewflow_sink(sink),
            Err(LinuxApplicationAudioError::InvalidModuleId)
        ));
        assert!(control.private_sink_is_unresolved(sink));
        assert!(matches!(
            control.create_viewflow_sink(sink),
            Err(LinuxApplicationAudioError::PrivateSinkUncertain)
        ));
        assert_eq!(control.runner().calls.len(), 1);
    }
}
