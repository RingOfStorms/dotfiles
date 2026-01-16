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

    fn parse(input: &str) -> Option<Self> {
        let normalized = input
            .trim()
            .to_lowercase()
            .replace('.', "-")
            .replace('_', "-");

        match normalized.as_str() {
            "tiny" => Some(ModelSize::Tiny),
            "tiny-en" => Some(ModelSize::TinyEn),
            "base" => Some(ModelSize::Base),
            "base-en" => Some(ModelSize::BaseEn),
            "small" => Some(ModelSize::Small),
            "small-en" => Some(ModelSize::SmallEn),
            "medium" => Some(ModelSize::Medium),
            "medium-en" => Some(ModelSize::MediumEn),
            "large-v3" => Some(ModelSize::LargeV3),
            _ => None,
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

    /// Number of threads for transcription (default: auto-detect)
    #[arg(long)]
    threads: Option<i32>,
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
    /// Manual mode: stop requested, finalize next tick
    pending_finalize: bool,
}

impl AudioState {
    fn new() -> Self {
        Self {
            buffer: Vec::with_capacity(16000 * 30), // 30 seconds max
            is_recording: false,
            speech_detected: false,
            silence_samples: 0,
            last_partial: std::time::Instant::now(),
            pending_finalize: false,
        }
    }

    fn clear(&mut self) {
        self.buffer.clear();
        self.speech_detected = false;
        self.silence_samples = 0;
        self.pending_finalize = false;
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

    let mut args = Args::parse();

    // Allow Nix/session configuration via env vars.
    // Precedence: explicit CLI args > env vars > defaults.
    //
    // `ringofstorms.sttIme.model` uses dot notation (e.g. "tiny.en"),
    // while clap's value enum expects kebab-case (e.g. "tiny-en").
    let cli_has_model_flag = std::env::args().any(|a| a == "--model" || a == "-M");
    if !cli_has_model_flag && args.model_path.is_none() {
        if let Ok(model) = std::env::var("STT_STREAM_MODEL") {
            if let Some(parsed) = ModelSize::parse(&model) {
                args.model = parsed;
            }
        }
    }

    info!("Starting stt-stream with mode: {:?}", args.mode);

    // Load Whisper model
    let model_path = get_model_path(&args).context("Failed to get model path")?;
    info!("Loading Whisper model from: {}", model_path);

    // Configure GPU and context parameters
    let mut ctx_params = WhisperContextParameters::default();
    
    // Check for GPU env var override
    let gpu_enabled = args.gpu || std::env::var("STT_STREAM_GPU").map(|v| v == "1" || v.to_lowercase() == "true").unwrap_or(false);
    
    ctx_params.use_gpu(gpu_enabled);
    if gpu_enabled {
        ctx_params.flash_attn(true); // Enable flash attention for GPU acceleration
    }

    // Determine thread counts
    let available_threads = std::thread::available_parallelism()
        .map(|p| p.get() as i32)
        .unwrap_or(4);
    let final_threads = args.threads.unwrap_or(available_threads.min(8));
    let partial_threads = (final_threads / 2).max(1);

    // Log backend configuration
    let gpu_feature_compiled = cfg!(feature = "hipblas") || cfg!(feature = "cuda") || cfg!(feature = "metal");
    info!("Backend configuration:");
    info!("  GPU requested: {}", gpu_enabled);
    info!("  GPU feature compiled: {} (hipblas={}, cuda={}, metal={})", 
        gpu_feature_compiled,
        cfg!(feature = "hipblas"),
        cfg!(feature = "cuda"),
        cfg!(feature = "metal")
    );
    info!("  Flash attention: {}", gpu_enabled);
    info!("  Model: {:?}", args.model);
    info!("  Threads (final/partial): {}/{}", final_threads, partial_threads);
    
    if gpu_enabled && !gpu_feature_compiled {
        warn!("GPU requested but no GPU feature compiled! Build with --features hipblas or --features cuda");
    }

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
                        state.pending_finalize = true;
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
                // In manual mode we normally ignore audio unless explicitly recording.
                // Exception: after receiving a "stop" command, we need one more tick
                // to finalize and emit the transcript.
                if !state.is_recording && !state.pending_finalize {
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
            let threads = partial_threads;

            // Transcribe in background
            tokio::task::spawn_blocking(move || {
                if let Ok(text) = transcribe(&ctx, &buffer_copy, &lang, false, threads) {
                    if !text.is_empty() {
                        emit_event(&SttEvent::Partial { text });
                    }
                }
            });
        }

        // Check for end of utterance
        let should_finalize = match current_mode {
            Mode::Manual => state.pending_finalize && state.speech_detected,
            Mode::Oneshot | Mode::Continuous => {
                state.speech_detected && state.silence_samples > silence_samples_threshold
            }
        };

        if should_finalize && !state.buffer.is_empty() {
            let buffer_copy = state.buffer.clone();
            let ctx = whisper_ctx.clone();
            let lang = language.clone();

            // Final transcription
            match transcribe(&ctx, &buffer_copy, &lang, true, final_threads) {
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
    threads: i32,
) -> Result<String> {
    let start_time = std::time::Instant::now();
    
    let ctx = ctx.lock().map_err(|_| anyhow::anyhow!("Lock poisoned"))?;
    let mut state = ctx.create_state()?;

    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });

    // Configure threads
    params.set_n_threads(threads);

    // Configure for speed vs accuracy
    if is_final {
        // Final transcription: balanced speed and accuracy
        params.set_single_segment(false);
    } else {
        // Partial transcription: optimize for speed
        params.set_no_context(true);
        params.set_single_segment(true);      // Faster for streaming
        params.set_no_timestamps(true);       // We don't use timestamps for partials
        params.set_temperature_inc(0.0);      // Disable fallback retries for speed
    }

    params.set_language(Some(language));
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    params.set_suppress_blank(true);
    params.set_suppress_nst(true);

    // Run inference
    state.full(params, samples)?;

    let inference_time = start_time.elapsed();
    let audio_duration_secs = samples.len() as f32 / 16000.0;
    tracing::debug!(
        "Transcription took {:?} for {:.1}s audio (RTF: {:.2}x)",
        inference_time,
        audio_duration_secs,
        inference_time.as_secs_f32() / audio_duration_secs
    );

    // Collect segments
    let num_segments = state.full_n_segments();
    let mut text = String::new();

    for i in 0..num_segments {
        if let Some(segment) = state.get_segment(i) {
            if let Ok(segment_text) = segment.to_str_lossy() {
                text.push_str(&segment_text);
            }
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
