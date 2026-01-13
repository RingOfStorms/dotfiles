//! stt-stream: Local speech-to-text streaming CLI
//!
//! Captures audio from microphone, performs VAD, transcribes with Whisper,
//! and outputs JSON events to stdout for Fcitx5 integration.

use anyhow::{Context, Result};
use clap::{Parser, ValueEnum};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use rubato::{FftFixedInOut, Resampler};
use serde::{Deserialize, Serialize};
use std::io::{BufRead, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;
use tracing::{error, info, warn};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

/// Operating mode for the STT engine
#[derive(Debug, Clone, Copy, ValueEnum, PartialEq, Eq)]
pub enum Mode {
    /// Record until silence, transcribe, then reset (one-shot)
    Oneshot,
    /// Always listen, emit text when speech detected (continuous)
    Continuous,
    /// Manual start/stop via stdin commands
    Manual,
}

/// Whisper model size
#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum ModelSize {
    Tiny,
    TinyEn,
    Base,
    BaseEn,
    Small,
    SmallEn,
    Medium,
    MediumEn,
    LargeV3,
}

impl ModelSize {
    fn model_name(&self) -> &'static str {
        match self {
            ModelSize::Tiny => "tiny",
            ModelSize::TinyEn => "tiny.en",
            ModelSize::Base => "base",
            ModelSize::BaseEn => "base.en",
            ModelSize::Small => "small",
            ModelSize::SmallEn => "small.en",
            ModelSize::Medium => "medium",
            ModelSize::MediumEn => "medium.en",
            ModelSize::LargeV3 => "large-v3",
        }
    }

    fn hf_repo(&self) -> &'static str {
        "ggerganov/whisper.cpp"
    }

    fn hf_filename(&self) -> String {
        format!("ggml-{}.bin", self.model_name())
    }
}

#[derive(Parser, Debug)]
#[command(name = "stt-stream")]
#[command(about = "Local speech-to-text streaming for Fcitx5")]
struct Args {
    /// Operating mode
    #[arg(short, long, value_enum, default_value = "manual")]
    mode: Mode,

    /// Whisper model size
    #[arg(short = 'M', long, value_enum, default_value = "base-en")]
    model: ModelSize,

    /// Path to whisper model file (overrides --model)
    #[arg(long)]
    model_path: Option<String>,

    /// VAD threshold (0.0-1.0)
    #[arg(long, default_value = "0.5")]
    vad_threshold: f32,

    /// Silence duration (ms) to end utterance
    #[arg(long, default_value = "800")]
    silence_ms: u64,

    /// Emit partial transcripts while speaking
    #[arg(long, default_value = "true")]
    partials: bool,

    /// Partial transcript interval (ms)
    #[arg(long, default_value = "500")]
    partial_interval_ms: u64,

    /// Language code (e.g., "en", "ja", "auto")
    #[arg(short, long, default_value = "en")]
    language: String,

    /// Use GPU acceleration
    #[arg(long)]
    gpu: bool,
}

/// Events emitted to stdout as NDJSON
#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SttEvent {
    /// STT engine is ready
    Ready,
    /// Recording started
    RecordingStarted,
    /// Recording stopped
    RecordingStopped,
    /// Partial (unstable) transcript
    Partial { text: String },
    /// Final transcript
    Final { text: String },
    /// Error occurred
    Error { message: String },
    /// Engine shutting down
    Shutdown,
}

/// Commands received from stdin as NDJSON
#[derive(Debug, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum SttCommand {
    /// Start recording
    Start,
    /// Stop recording and transcribe
    Stop,
    /// Cancel current recording without transcribing
    Cancel,
    /// Shutdown the engine
    Shutdown,
    /// Switch mode
    SetMode { mode: String },
}

fn emit_event(event: &SttEvent) {
    if let Ok(json) = serde_json::to_string(event) {
        let mut stdout = std::io::stdout().lock();
        let _ = writeln!(stdout, "{}", json);
        let _ = stdout.flush();
    }
}

/// Simple energy-based VAD (placeholder for Silero VAD)
/// Returns true if the audio chunk likely contains speech
fn simple_vad(samples: &[f32], threshold: f32) -> bool {
    if samples.is_empty() {
        return false;
    }
    let energy: f32 = samples.iter().map(|s| s * s).sum::<f32>() / samples.len() as f32;
    let db = 10.0 * energy.max(1e-10).log10();
    // Typical speech is around -20 to -10 dB, silence is < -40 dB
    // Map threshold 0-1 to dB range -50 to -20
    let threshold_db = -50.0 + (threshold * 30.0);
    db > threshold_db
}

/// Download or locate the Whisper model
fn get_model_path(args: &Args) -> Result<String> {
    if let Some(ref path) = args.model_path {
        return Ok(path.clone());
    }

    // Check environment variable
    if let Ok(path) = std::env::var("STT_STREAM_MODEL_PATH") {
        if std::path::Path::new(&path).exists() {
            return Ok(path);
        }
    }

    // Check XDG cache
    let cache_dir = dirs::cache_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("stt-stream")
        .join("models");

    let model_file = cache_dir.join(args.model.hf_filename());
    if model_file.exists() {
        return Ok(model_file.to_string_lossy().to_string());
    }

    // Download from Hugging Face
    info!("Downloading model {} from Hugging Face...", args.model.model_name());
    std::fs::create_dir_all(&cache_dir)?;

    let api = hf_hub::api::sync::Api::new()?;
    let repo = api.model(args.model.hf_repo().to_string());
    let path = repo.get(&args.model.hf_filename())?;

    Ok(path.to_string_lossy().to_string())
}

/// Audio processing state
struct AudioState {
    /// Audio samples buffer (16kHz mono)
    buffer: Vec<f32>,
    /// Whether we're currently recording
    is_recording: bool,
    /// Whether speech was detected in current segment
    speech_detected: bool,
    /// Samples since last speech
    silence_samples: usize,
    /// Last partial emission time
    last_partial: std::time::Instant,
}

impl AudioState {
    fn new() -> Self {
        Self {
            buffer: Vec::with_capacity(16000 * 30), // 30 seconds max
            is_recording: false,
            speech_detected: false,
            silence_samples: 0,
            last_partial: std::time::Instant::now(),
        }
    }

    fn clear(&mut self) {
        self.buffer.clear();
        self.speech_detected = false;
        self.silence_samples = 0;
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("stt_stream=info".parse().unwrap()),
        )
        .with_writer(std::io::stderr)
        .init();

    let args = Args::parse();
    info!("Starting stt-stream with mode: {:?}", args.mode);

    // Load Whisper model
    let model_path = get_model_path(&args).context("Failed to get model path")?;
    info!("Loading Whisper model from: {}", model_path);

    let ctx_params = WhisperContextParameters::default();
    let whisper_ctx = WhisperContext::new_with_params(&model_path, ctx_params)
        .context("Failed to load Whisper model")?;

    let whisper_ctx = Arc::new(Mutex::new(whisper_ctx));

    // Audio capture setup
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .context("No input device available")?;

    info!("Using input device: {}", device.name().unwrap_or_default());

    let config = device.default_input_config()?;
    let sample_rate = config.sample_rate().0;
    let channels = config.channels() as usize;

    info!("Input config: {}Hz, {} channels", sample_rate, channels);

    // Resampler: input rate -> 16kHz
    let resampler = if sample_rate != 16000 {
        Some(Arc::new(Mutex::new(
            FftFixedInOut::<f32>::new(sample_rate as usize, 16000, 1024, 1)
                .context("Failed to create resampler")?,
        )))
    } else {
        None
    };

    // Shared state
    let audio_state = Arc::new(Mutex::new(AudioState::new()));
    let running = Arc::new(AtomicBool::new(true));
    let mode = Arc::new(Mutex::new(args.mode));

    // Channel for audio data
    let (audio_tx, mut audio_rx) = mpsc::channel::<Vec<f32>>(100);

    // Audio callback
    let resampler_clone = resampler.clone();
    let running_clone = running.clone();

    let stream = device.build_input_stream(
        &config.into(),
        move |data: &[f32], _: &cpal::InputCallbackInfo| {
            if !running_clone.load(Ordering::Relaxed) {
                return;
            }

            // Convert to mono if needed
            let mono: Vec<f32> = if channels > 1 {
                data.chunks(channels)
                    .map(|frame| frame.iter().sum::<f32>() / channels as f32)
                    .collect()
            } else {
                data.to_vec()
            };

            // Resample if needed
            let resampled = if let Some(ref resampler) = resampler_clone {
                if let Ok(mut r) = resampler.lock() {
                    // Pad input to required length
                    let input_frames = r.input_frames_next();
                    if mono.len() >= input_frames {
                        let input = vec![mono[..input_frames].to_vec()];
                        match r.process(&input, None) {
                            Ok(output) => output.into_iter().flatten().collect(),
                            Err(_) => return,
                        }
                    } else {
                        return;
                    }
                } else {
                    return;
                }
            } else {
                mono
            };

            let _ = audio_tx.blocking_send(resampled);
        },
        |err| {
            error!("Audio stream error: {}", err);
        },
        None,
    )?;

    stream.play()?;
    emit_event(&SttEvent::Ready);

    // Stdin command reader
    let running_stdin = running.clone();
    let mode_stdin = mode.clone();
    let audio_state_stdin = audio_state.clone();

    let stdin_handle = std::thread::spawn(move || {
        let stdin = std::io::stdin();
        for line in stdin.lock().lines() {
            if !running_stdin.load(Ordering::Relaxed) {
                break;
            }

            let line = match line {
                Ok(l) => l,
                Err(_) => continue,
            };

            let cmd: SttCommand = match serde_json::from_str(&line) {
                Ok(c) => c,
                Err(_) => {
                    // Try simple text commands
                    match line.trim().to_lowercase().as_str() {
                        "start" => SttCommand::Start,
                        "stop" => SttCommand::Stop,
                        "cancel" => SttCommand::Cancel,
                        "shutdown" | "quit" | "exit" => SttCommand::Shutdown,
                        _ => continue,
                    }
                }
            };

            match cmd {
                SttCommand::Start => {
                    if let Ok(mut state) = audio_state_stdin.lock() {
                        state.is_recording = true;
                        state.clear();
                        emit_event(&SttEvent::RecordingStarted);
                    }
                }
                SttCommand::Stop => {
                    if let Ok(mut state) = audio_state_stdin.lock() {
                        state.is_recording = false;
                        emit_event(&SttEvent::RecordingStopped);
                    }
                }
                SttCommand::Cancel => {
                    if let Ok(mut state) = audio_state_stdin.lock() {
                        state.is_recording = false;
                        state.clear();
                        emit_event(&SttEvent::RecordingStopped);
                    }
                }
                SttCommand::Shutdown => {
                    running_stdin.store(false, Ordering::Relaxed);
                    break;
                }
                SttCommand::SetMode { mode: m } => {
                    if let Ok(mut current_mode) = mode_stdin.lock() {
                        *current_mode = match m.as_str() {
                            "oneshot" => Mode::Oneshot,
                            "continuous" => Mode::Continuous,
                            "manual" => Mode::Manual,
                            _ => continue,
                        };
                    }
                }
            }
        }
    });

    // Main processing loop
    let vad_threshold = args.vad_threshold;
    let silence_samples_threshold = (args.silence_ms as f32 * 16.0) as usize; // 16 samples per ms at 16kHz
    let partial_interval = std::time::Duration::from_millis(args.partial_interval_ms);
    let emit_partials = args.partials;
    let language = args.language.clone();

    while running.load(Ordering::Relaxed) {
        // Receive audio data
        let samples = match tokio::time::timeout(
            std::time::Duration::from_millis(100),
            audio_rx.recv(),
        )
        .await
        {
            Ok(Some(s)) => s,
            Ok(None) => break,
            Err(_) => continue, // Timeout, check running flag
        };

        let current_mode = *mode.lock().unwrap();
        let mut state = audio_state.lock().unwrap();

        // Mode-specific behavior
        match current_mode {
            Mode::Manual => {
                if !state.is_recording {
                    continue;
                }
            }
            Mode::Oneshot | Mode::Continuous => {
                // Auto-start on speech detection
                let has_speech = simple_vad(&samples, vad_threshold);

                if !state.is_recording && has_speech {
                    state.is_recording = true;
                    state.clear();
                    emit_event(&SttEvent::RecordingStarted);
                }

                if !state.is_recording {
                    continue;
                }
            }
        }

        // Accumulate audio
        state.buffer.extend_from_slice(&samples);

        // VAD check
        let has_speech = simple_vad(&samples, vad_threshold);
        if has_speech {
            state.speech_detected = true;
            state.silence_samples = 0;
        } else {
            state.silence_samples += samples.len();
        }

        // Emit partial transcript if enabled
        if emit_partials
            && state.speech_detected
            && state.last_partial.elapsed() > partial_interval
            && state.buffer.len() > 16000 // At least 1 second
        {
            state.last_partial = std::time::Instant::now();
            let buffer_copy = state.buffer.clone();
            let ctx = whisper_ctx.clone();
            let lang = language.clone();

            // Transcribe in background
            tokio::task::spawn_blocking(move || {
                if let Ok(text) = transcribe(&ctx, &buffer_copy, &lang, false) {
                    if !text.is_empty() {
                        emit_event(&SttEvent::Partial { text });
                    }
                }
            });
        }

        // Check for end of utterance
        let should_finalize = match current_mode {
            Mode::Manual => !state.is_recording && state.speech_detected,
            Mode::Oneshot | Mode::Continuous => {
                state.speech_detected && state.silence_samples > silence_samples_threshold
            }
        };

        if should_finalize && !state.buffer.is_empty() {
            let buffer_copy = state.buffer.clone();
            let ctx = whisper_ctx.clone();
            let lang = language.clone();

            // Final transcription
            match transcribe(&ctx, &buffer_copy, &lang, true) {
                Ok(text) => {
                    if !text.is_empty() {
                        emit_event(&SttEvent::Final { text });
                    }
                }
                Err(e) => {
                    emit_event(&SttEvent::Error {
                        message: e.to_string(),
                    });
                }
            }

            state.clear();
            state.is_recording = current_mode == Mode::Continuous;

            if current_mode == Mode::Oneshot {
                emit_event(&SttEvent::RecordingStopped);
            }
        }

        // Prevent buffer from growing too large
        if state.buffer.len() > 16000 * 30 {
            warn!("Buffer too large, truncating");
            let start = state.buffer.len() - 16000 * 20;
            state.buffer = state.buffer[start..].to_vec();
        }
    }

    // Cleanup
    drop(stream);
    emit_event(&SttEvent::Shutdown);
    let _ = stdin_handle.join();

    Ok(())
}

/// Transcribe audio buffer using Whisper
fn transcribe(
    ctx: &Arc<Mutex<WhisperContext>>,
    samples: &[f32],
    language: &str,
    is_final: bool,
) -> Result<String> {
    let ctx = ctx.lock().map_err(|_| anyhow::anyhow!("Lock poisoned"))?;
    let mut state = ctx.create_state()?;

    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });

    // Configure for speed vs accuracy
    if is_final {
        params.set_n_threads(4);
    } else {
        params.set_n_threads(2);
        params.set_no_context(true);
    }

    params.set_language(Some(language));
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    params.set_suppress_blank(true);
    params.set_suppress_non_speech_tokens(true);

    // Run inference
    state.full(params, samples)?;

    // Collect segments
    let num_segments = state.full_n_segments()?;
    let mut text = String::new();

    for i in 0..num_segments {
        if let Ok(segment) = state.full_get_segment_text(i) {
            text.push_str(&segment);
        }
    }

    Ok(text.trim().to_string())
}

/// Stub for dirs crate functionality
mod dirs {
    use std::path::PathBuf;

    pub fn cache_dir() -> Option<PathBuf> {
        std::env::var("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .ok()
            .or_else(|| {
                std::env::var("HOME")
                    .map(|h| PathBuf::from(h).join(".cache"))
                    .ok()
            })
    }
}
