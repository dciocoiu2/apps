# srnrec_deploy.ps1
# Fully deploy offline screen recorder + transcription environment
# Creates directories, downloads ffmpeg, Vosk models, Vosk wheel, and writes full app.py

param(
    [string]$PythonPath = "python"  # Path to python.exe if not in PATH
)

Write-Host "=== Deploying ScreenSTT Environment ==="

# Base directories
$baseDir = (Get-Location).Path
$binDir = Join-Path $baseDir "bin"
$modelsDir = Join-Path $baseDir "models"
$wheelsDir = Join-Path $baseDir "wheels"
$outDir = Join-Path $baseDir "out"
$logsDir = Join-Path $baseDir "logs"

# Create directories
$dirs = @($binDir, $modelsDir, $wheelsDir, $outDir, $logsDir)
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d | Out-Null
        Write-Host "Created $d"
    }
}

# --- Download ffmpeg (Windows essentials build) ---
$ffmpegUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
$ffmpegZip = Join-Path $binDir "ffmpeg.zip"
Write-Host "Downloading ffmpeg..."
Invoke-WebRequest -Uri $ffmpegUrl -OutFile $ffmpegZip
Expand-Archive -Path $ffmpegZip -DestinationPath $binDir -Force
Remove-Item $ffmpegZip
# Move ffmpeg.exe to bin/
$ffmpegExe = Get-ChildItem -Path $binDir -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
if ($ffmpegExe) {
    Copy-Item $ffmpegExe.FullName $binDir -Force
    Write-Host "ffmpeg deployed to $binDir"
} else {
    Write-Host "Warning: ffmpeg.exe not found after extraction. Please verify."
}

# --- Download Vosk models (English small + large) ---
$voskSmallUrl = "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"
$voskLargeUrl = "https://alphacephei.com/vosk/models/vosk-model-en-us-0.22.zip"

$voskSmallZip = Join-Path $modelsDir "vosk-small.zip"
$voskLargeZip = Join-Path $modelsDir "vosk-large.zip"

Write-Host "Downloading Vosk small model..."
Invoke-WebRequest -Uri $voskSmallUrl -OutFile $voskSmallZip
Expand-Archive -Path $voskSmallZip -DestinationPath $modelsDir -Force
Remove-Item $voskSmallZip

Write-Host "Downloading Vosk large model..."
Invoke-WebRequest -Uri $voskLargeUrl -OutFile $voskLargeZip
Expand-Archive -Path $voskLargeZip -DestinationPath $modelsDir -Force
Remove-Item $voskLargeZip

# --- Download Vosk wheel (adjust for your Python version/arch if needed) ---
$voskWheelUrl = "https://github.com/alphacep/vosk-api/releases/download/v0.3.45/vosk-0.3.45-cp311-cp311-win_amd64.whl"
$voskWheelFile = Join-Path $wheelsDir "vosk-0.3.45-cp311-cp311-win_amd64.whl"
Write-Host "Downloading Vosk wheel..."
Invoke-WebRequest -Uri $voskWheelUrl -OutFile $voskWheelFile

# --- Write full app.py ---
$appFile = Join-Path $baseDir "app.py"
Write-Host "Writing full app.py..."
@"
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
app.py - Single-file offline screen recorder + transcription + training launcher
- Runs entirely from a single directory with local binaries and models.
- Requires only Python on the host system.
- Expects:
    ./bin/ffmpeg.exe (Windows) or ./bin/ffmpeg (Linux/macOS)
    ./models/<vosk-model-*>
    ./wheels/<vosk-*.whl> (optional; used if vosk not installed)
- Features:
    - record: capture screen + audio to MP4 using local ffmpeg
    - transcribe: offline transcription using local Vosk model
    - export: mux soft subs, burn subs, or extract audio
    - prepare-corpus: normalize audio corpus to mono 16k WAV and produce manifest
    - train: launcher to call a local training script (user-provided) to build models
"""

from __future__ import annotations
import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import time
import wave
import datetime
import tempfile
import uuid
from pathlib import Path
from typing import List, Optional, Tuple

APP_NAME = "screenstt"
BASE_DIR = Path(os.getcwd()).resolve()
BIN_DIR = BASE_DIR / "bin"
MODELS_DIR = BASE_DIR / "models"
OUT_DIR = BASE_DIR / "out"
LOGS_DIR = BASE_DIR / "logs"
WHEELS_DIR = BASE_DIR / "wheels"
TRAIN_DIR = BASE_DIR / "train"

# Ensure output directories exist
def ensure_dirs():
    for d in (OUT_DIR, LOGS_DIR):
        d.mkdir(parents=True, exist_ok=True)

def log_path() -> Path:
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    return LOGS_DIR / f"{APP_NAME}_{ts}.log"

def write_log(msg: str, logf=None, also_print: bool = True):
    line = f"{datetime.datetime.now().isoformat()} | {msg}"
    if also_print:
        print(line)
    if logf:
        logf.write(line + "\n")
        logf.flush()

# Attempt to load vosk from local wheel(s) if not installed
def add_local_wheel(package_name: str = "vosk") -> bool:
    try:
        __import__(package_name)
        return True
    except Exception:
        pass
    if not WHEELS_DIR.exists():
        return False
    wheels = sorted([p for p in WHEELS_DIR.iterdir() if p.suffix == ".whl" and package_name in p.name], key=lambda x: x.name)
    for whl in wheels:
        sys.path.insert(0, str(whl))
        try:
            __import__(package_name)
            return True
        except Exception:
            continue
    return False

if not add_local_wheel("vosk"):
    # If vosk not available via wheel or environment, exit with helpful message
    print("Error: Vosk is not available. Place a platform-appropriate vosk wheel in ./wheels or install vosk in your Python environment.")
    sys.exit(2)

from vosk import Model, KaldiRecognizer  # type: ignore

# Utilities to find ffmpeg
def find_ffmpeg() -> Optional[str]:
    system = platform.system().lower()
    candidates = []
    if system == "windows":
        candidates.append(str(BIN_DIR / "ffmpeg.exe"))
    else:
        candidates.append(str(BIN_DIR / "ffmpeg"))
    # fallback to PATH
    path_ff = shutil.which("ffmpeg")
    if path_ff:
        candidates.append(path_ff)
    for c in candidates:
        if c and Path(c).exists():
            return c
    return None

# Default backends per OS
def default_screen_backend() -> str:
    system = platform.system().lower()
    if system == "windows":
        return "gdigrab"
    if system == "darwin":
        return "avfoundation"
    return "x11grab"

def default_audio_backend() -> str:
    system = platform.system().lower()
    if system == "windows":
        return "dshow"
    if system == "darwin":
        return "avfoundation"
    # prefer pulse on linux
    return "pulse"

# Build ffmpeg input args for screen
def screen_input_args(backend: str, screen_region: Optional[Tuple[int,int,int,int]], fps: int, capture_display: Optional[int]) -> List[str]:
    args: List[str] = []
    if backend == "gdigrab":
        if screen_region:
            x,y,w,h = screen_region
            args += ["-f", "gdigrab", "-framerate", str(fps), "-offset_x", str(x), "-offset_y", str(y), "-video_size", f"{w}x{h}", "-i", "desktop"]
        else:
            args += ["-f", "gdigrab", "-framerate", str(fps), "-i", "desktop"]
    elif backend == "avfoundation":
        scr = "1" if capture_display is None else str(capture_display)
        # avfoundation uses "<video_index>:<audio_index>" for -i; we will capture screen only here and audio separately
        args += ["-f", "avfoundation", "-framerate", str(fps), "-i", f"{scr}:none"]
    elif backend == "x11grab":
        display = os.environ.get("DISPLAY", ":0.0")
        if screen_region:
            x,y,w,h = screen_region
            args += ["-f", "x11grab", "-framerate", str(fps), "-video_size", f"{w}x{h}", "-i", f"{display}+{x},{y}"]
        else:
            args += ["-f", "x11grab", "-framerate", str(fps), "-i", display]
    else:
        raise ValueError(f"Unsupported screen backend: {backend}")
    return args

# Build ffmpeg input args for audio
def audio_input_args(backend: str, audio_device: Optional[str]) -> List[str]:
    args: List[str] = []
    if backend == "dshow":
        dev = audio_device if audio_device else "audio=Microphone"
        args += ["-f", "dshow", "-i", dev]
    elif backend == "avfoundation":
        dev = "none:0" if audio_device is None else audio_device
        args += ["-f", "avfoundation", "-i", dev]
    elif backend == "pulse":
        dev = audio_device if audio_device else "default"
        args += ["-f", "pulse", "-i", dev]
    elif backend == "alsa":
        dev = audio_device if audio_device else "default"
        args += ["-f", "alsa", "-i", dev]
    else:
        raise ValueError(f"Unsupported audio backend: {backend}")
    return args

# Recording function using ffmpeg
def record(ffmpeg: str,
           out_video_path: Path,
           duration: Optional[int] = None,
           screen_backend: Optional[str] = None,
           audio_backend: Optional[str] = None,
           fps: int = 30,
           screen_region: Optional[Tuple[int,int,int,int]] = None,
           audio_device: Optional[str] = None,
           bitrate: str = "4M",
           video_size: Optional[str] = None,
           capture_display: Optional[int] = None,
           audio_codec: str = "aac",
           video_codec: str = "h264",
           crf: int = 23,
           preset: str = "veryfast",
           logf=None) -> Path:
    ensure_dirs()
    screen_backend = screen_backend or default_screen_backend()
    audio_backend = audio_backend or default_audio_backend()

    write_log(f"Recording start -> video={out_video_path}", logf)
    sargs = screen_input_args(screen_backend, screen_region, fps, capture_display)
    aargs = audio_input_args(audio_backend, audio_device)

    vsize_args: List[str] = []
    if video_size:
        vsize_args = ["-vf", f"scale={video_size}"]

    out_args = ["-c:v", video_codec, "-preset", preset, "-crf", str(crf), "-b:v", bitrate,
                "-c:a", audio_codec, "-pix_fmt", "yuv420p"]

    cmd = [ffmpeg, "-hide_banner", "-y"] + sargs + aargs
    if duration:
        cmd += ["-t", str(duration)]
    cmd += vsize_args + out_args + [str(out_video_path)]

    write_log(f"ffmpeg command: {' '.join(cmd)}", logf)
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    assert proc.stdout is not None
    for line in proc.stdout:
        write_log(line.strip(), logf, also_print=False)
    rc = proc.wait()
    write_log(f"Recording finished rc={rc}", logf)
    if rc != 0:
        raise RuntimeError(f"ffmpeg recording failed rc={rc}")
    return out_video_path

# Extract audio to mono 16k WAV for Vosk
def extract_audio(ffmpeg: str, input_video: Path, out_wav_path: Path, sample_rate: int = 16000, channels: int = 1, logf=None) -> Path:
    ensure_dirs()
    cmd = [ffmpeg, "-hide_banner", "-y", "-i", str(input_video), "-ac", str(channels),
           "-ar", str(sample_rate), "-vn", "-f", "wav", str(out_wav_path)]
    write_log(f"Extract audio: {' '.join(cmd)}", logf)
    rc = subprocess.call(cmd)
    if rc != 0:
        raise RuntimeError("Audio extraction failed")
    return out_wav_path

# Read WAV frames helper
def read_wav_frames(path: Path) -> Tuple[int,int,int,bytes]:
    with wave.open(str(path), "rb") as wf:
        nch = wf.getnchannels()
        rate = wf.getframerate()
        width = wf.getsampwidth()
        frames = wf.getnframes()
        data = wf.readframes(frames)
    return nch, rate, width, data

# Load Vosk model
def load_model(model_dir: Path) -> Model:
    if not validate_model_dir(model_dir):
        raise FileNotFoundError(f"Model directory invalid or not found: {model_dir}")
    return Model(str(model_dir))

# Recognize WAV using Vosk
def recognize_wav(model: Model, wav_path: Path, phrase_bias: Optional[List[str]] = None, words: bool = True, logf=None):
    nch, rate, width, data = read_wav_frames(wav_path)
    if phrase_bias and isinstance(phrase_bias, list) and len(phrase_bias) > 0:
        rec = KaldiRecognizer(model, rate, json.dumps(phrase_bias))
    else:
        rec = KaldiRecognizer(model, rate)
    rec.SetWords(words)

    chunk_size = 4000
    buf = memoryview(data)
    results = []
    pos = 0
    while pos < len(buf):
        end = min(len(buf), pos + chunk_size)
        rec.AcceptWaveform(buf[pos:end].tobytes())
        pos = end
    final = json.loads(rec.FinalResult())
    if "result" in final:
        results.append(final)
    return results

# Build SRT from word-level timestamps
def srt_from_words(results, max_gap: float = 0.8, max_len_chars: int = 80) -> str:
    def fmt_ts(t: float) -> str:
        ms = int((t - int(t)) * 1000)
        s = int(t)
        h = s // 3600
        m = (s % 3600) // 60
        sec = s % 60
        return f"{h:02}:{m:02}:{sec:02},{ms:03}"

    words = []
    for r in results:
        for w in r.get("result", []):
            words.append(w)
    if not words:
        return ""

    cues = []
    cur = {"start": words[0]["start"], "end": words[0]["end"], "text": words[0]["word"]}
    for i in range(1, len(words)):
        w = words[i]
        gap = w["start"] - words[i-1]["end"]
        if gap > max_gap or len(cur["text"]) + 1 + len(w["word"]) > max_len_chars:
            cues.append(cur)
            cur = {"start": w["start"], "end": w["end"], "text": w["word"]}
        else:
            cur["end"] = w["end"]
            cur["text"] += " " + w["word"]
    cues.append(cur)

    lines = []
    for idx, c in enumerate(cues, 1):
        lines.append(f"{idx}")
        lines.append(f"{fmt_ts(c['start'])} --> {fmt_ts(c['end'])}")
        lines.append(c["text"])
        lines.append("")
    return "\n".join(lines)

# Save TXT transcript
def save_txt_transcript(results, out_txt: Path) -> Path:
    text = " ".join([r.get("text", "") for r in results]).strip()
    out_txt.write_text(text if text else "", encoding="utf-8")
    return out_txt

# Save SRT transcript
def save_srt_transcript(results, out_srt: Path) -> Path:
    srt = srt_from_words(results)
    out_srt.write_text(srt if srt else "", encoding="utf-8")
    return out_srt

# Mux soft subtitles into MP4 (mov_text)
def mux_soft_subs(ffmpeg: str, input_mp4: Path, srt_path: Path, out_mp4: Path, logf=None) -> Path:
    cmd = [ffmpeg, "-hide_banner", "-y", "-i", str(input_mp4), "-i", str(srt_path),
           "-c", "copy", "-c:s", "mov_text", str(out_mp4)]
    write_log(f"Mux soft subs: {' '.join(cmd)}", logf)
    rc = subprocess.call(cmd)
    if rc != 0:
        raise RuntimeError("Subtitles muxing failed")
    return out_mp4

# Burn subtitles into video using ffmpeg subtitles filter
def burn_subs(ffmpeg: str, input_mp4: Path, srt_path: Path, out_mp4: Path, logf=None) -> Path:
    cmd = [ffmpeg, "-hide_banner", "-y", "-i", str(input_mp4),
           "-vf", f"subtitles={str(srt_path)}",
           "-c:a", "copy",
           str(out_mp4)]
    write_log(f"Burn subs: {' '.join(cmd)}", logf)
    rc = subprocess.call(cmd)
    if rc != 0:
        raise RuntimeError("Burned subtitles export failed")
    return out_mp4

# Export audio-only
def export_audio_only(ffmpeg: str, input_mp4: Path, out_audio: Path, audio_codec: str = "mp3", logf=None) -> Path:
    if out_audio.suffix.lower() == ".wav":
        cmd = [ffmpeg, "-hide_banner", "-y", "-i", str(input_mp4), "-vn", "-acodec", "pcm_s16le", str(out_audio)]
    else:
        cmd = [ffmpeg, "-hide_banner", "-y", "-i", str(input_mp4), "-vn", "-c:a", audio_codec, str(out_audio)]
    write_log(f"Export audio-only: {' '.join(cmd)}", logf)
    rc = subprocess.call(cmd)
    if rc != 0:
        raise RuntimeError("Audio-only export failed")
    return out_audio

# Validate model directory (lenient)
def validate_model_dir(model_dir: Path) -> bool:
    if not model_dir or not model_dir.exists() or not model_dir.is_dir():
        return False
    return any(model_dir.iterdir())

# List available models
def list_models() -> List[Path]:
    if not MODELS_DIR.exists():
        return []
    return [d for d in MODELS_DIR.iterdir() if d.is_dir() and validate_model_dir(d)]

# Prepare corpus: normalize audio files to mono 16k WAV and create manifest
def prepare_wav_corpus(ffmpeg: str, in_dir: Path, out_dir: Path, target_sr: int = 16000) -> Path:
    if not ffmpeg:
        raise FileNotFoundError("ffmpeg not found")
    out_dir.mkdir(parents=True, exist_ok=True)
    in_dir = in_dir.resolve()
    manifest = []
    for p in in_dir.rglob("*"):
        if p.suffix.lower() in [".wav", ".mp3", ".m4a", ".flac", ".ogg"]:
            outp = out_dir / (p.stem + ".wav")
            cmd = [ffmpeg, "-hide_banner", "-y", "-i", str(p), "-ac", "1", "-ar", str(target_sr), str(outp)]
            subprocess.check_call(cmd)
            txtp = p.with_suffix(".txt")
            transcript = txtp.read_text(encoding="utf-8").strip() if txtp.exists() else ""
            manifest.append({"audio": str(outp), "text": transcript})
    manifest_path = out_dir / "corpus.jsonl"
    manifest_path.write_text("\n".join(json.dumps(x) for x in manifest), encoding="utf-8")
    return manifest_path

# Training launcher: calls a user-provided training script under ./train/
def launch_training(corpus_manifest: Path, out_model_dir: Path, logf=None) -> Path:
    # Expect a training script at ./train/run_train.bat or run_train.sh depending on platform
    if not TRAIN_DIR.exists():
        raise FileNotFoundError("Training toolchain directory './train' not found. Place your training scripts there.")
    # Prefer platform-specific script
    system = platform.system().lower()
    if system == "windows":
        script = TRAIN_DIR / "run_train.bat"
    else:
        script = TRAIN_DIR / "run_train.sh"
    if not script.exists():
        raise FileNotFoundError(f"Training script not found: {script}")
    cmd = [str(script), str(corpus_manifest), str(out_model_dir)]
    write_log(f"Launching training: {' '.join(cmd)}", logf)
    rc = subprocess.call(cmd)
    if rc != 0:
        raise RuntimeError("Training failed")
    if not out_model_dir.exists():
        raise RuntimeError("Training completed but output model directory not found")
    return out_model_dir

# Auto-select default model
def default_model_dir() -> Optional[Path]:
    if not MODELS_DIR.exists():
        return None
    prefs = [
        "vosk-model-en-us-0.22",
        "vosk-model-en-us-daanzu-20200905",
        "vosk-model-small-en-us-0.15",
    ]
    for p in prefs:
        md = MODELS_DIR / p
        if md.exists():
            return md
    # fallback to first valid directory
    for d in MODELS_DIR.iterdir():
        if d.is_dir() and validate_model_dir(d):
            return d
    return None

# CLI
def main():
    ensure_dirs()
    parser = argparse.ArgumentParser(description="Offline screen recorder + transcription (single-file, local wheels/models/bin)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    # Record
    p_rec = sub.add_parser("record", help="Record screen + audio to MP4")
    p_rec.add_argument("--out", type=str, default=str(OUT_DIR / f"{APP_NAME}_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.mp4"))
    p_rec.add_argument("--duration", type=int, default=None)
    p_rec.add_argument("--fps", type=int, default=30)
    p_rec.add_argument("--screen-backend", type=str, default=None, choices=["gdigrab", "avfoundation", "x11grab"])
    p_rec.add_argument("--audio-backend", type=str, default=None, choices=["dshow", "avfoundation", "pulse", "alsa"])
    p_rec.add_argument("--audio-device", type=str, default=None)
    p_rec.add_argument("--region", type=str, default=None, help="x,y,w,h (Windows/Linux)")
    p_rec.add_argument("--bitrate", type=str, default="4M")
    p_rec.add_argument("--video-size", type=str, default=None, help="e.g., 1920x1080")
    p_rec.add_argument("--video-codec", type=str, default="h264")
    p_rec.add_argument("--audio-codec", type=str, default="aac")
    p_rec.add_argument("--crf", type=int, default=23)
    p_rec.add_argument("--preset", type=str, default="veryfast")
    p_rec.add_argument("--display", type=int, default=None, help="macOS avfoundation display index")

    # Transcribe
    p_tr = sub.add_parser("transcribe", help="Transcribe MP4/WAV to TXT/SRT using local Vosk model")
    p_tr.add_argument("--in", dest="inp", type=str, required=True)
    p_tr.add_argument("--model", type=str, default=None, help="Path or name under ./models; default auto-selects best available")
    p_tr.add_argument("--txt-out", type=str, default=None)
    p_tr.add_argument("--srt-out", type=str, default=None)
    p_tr.add_argument("--phrase-bias", type=str, default=None, help="Path to JSON list of domain phrases")
    p_tr.add_argument("--keep-wav", action="store_true")

    # Export
    p_ex = sub.add_parser("export", help="Export MP4+subs or audio-only")
    p_ex.add_argument("--in", dest="inp", type=str, required=True)
    p_ex.add_argument("--srt", type=str, required=True)
    p_ex.add_argument("--mode", type=str, required=True, choices=["softsubs", "burn", "audio"])
    p_ex.add_argument("--out", type=str, required=True)
    p_ex.add_argument("--audio-codec", type=str, default="mp3")

    # Models list
    p_ls = sub.add_parser("models", help="List available local models")

    # Prepare corpus
    p_cp = sub.add_parser("prepare-corpus", help="Normalize audio corpus to mono 16k WAV and build manifest")
    p_cp.add_argument("--in", dest="inp", type=str, required=True)
    p_cp.add_argument("--out", dest="out", type=str, required=True)

    # Train launcher
    p_train = sub.add_parser("train", help="Launch local training script to build a model")
    p_train.add_argument("--corpus", type=str, required=True, help="Path to corpus.jsonl produced by prepare-corpus")
    p_train.add_argument("--out", type=str, required=True, help="Output model directory (will be created under ./models if relative)")

    args = parser.parse_args()
    lp = log_path()
    with lp.open("a", encoding="utf-8") as logf:
        write_log(f"Command: {args.cmd}", logf)
        ffmpeg = find_ffmpeg()
        if not ffmpeg:
            write_log("Error: ffmpeg binary not found in ./bin or PATH.", logf)
            print("Error: ffmpeg binary not found in ./bin or PATH.")
            sys.exit(1)

        if args.cmd == "record":
            region = None
            if args.region:
                try:
                    x, y, w, h = [int(v) for v in args.region.split(",")]
                    region = (x, y, w, h)
                except Exception:
                    write_log("Invalid --region format. Use x,y,w,h.", logf)
                    print("Invalid --region format. Use x,y,w,h.")
                    sys.exit(1)
            outp = Path(args.out)
            outp.parent.mkdir(parents=True, exist_ok=True)
            try:
                record(ffmpeg=ffmpeg,
                       out_video_path=outp,
                       duration=args.duration,
                       screen_backend=args.screen_backend,
                       audio_backend=args.audio_backend,
                       fps=args.fps,
                       screen_region=region,
                       audio_device=args.audio_device,
                       bitrate=args.bitrate,
                       video_size=args.video_size,
                       capture_display=args.display,
                       audio_codec=args.audio_codec,
                       video_codec=args.video_codec,
                       crf=args.crf,
                       preset=args.preset,
                       logf=logf)
            except Exception as e:
                write_log(f"Recording error: {e}", logf)
                print(f"Recording failed: {e}")
                sys.exit(1)
            write_log(f"Recorded: {outp}", logf)
            print(str(outp))

        elif args.cmd == "transcribe":
            inp = Path(args.inp)
            if not inp.exists():
                write_log("Input file not found.", logf)
                print("Input file not found.")
                sys.exit(1)
            # Resolve model
            model_dir = None
            if args.model:
                cand = Path(args.model)
                if not cand.exists():
                    cand = MODELS_DIR / args.model
                model_dir = cand
            else:
                model_dir = default_model_dir()
            if not model_dir or not validate_model_dir(model_dir):
                write_log("Model directory not found or invalid. Place a Vosk model under ./models.", logf)
                print("Model directory not found or invalid. Place a Vosk model under ./models.")
                sys.exit(1)

            phrase_bias = None
            if args.phrase_bias:
                pbp = Path(args.phrase_bias)
                if pbp.exists():
                    phrase_bias = json.loads(pbp.read_text(encoding="utf-8"))
                else:
                    write_log("Phrase bias file not found; ignoring.", logf)

            tmp_wav = OUT_DIR / f"tmp_{uuid.uuid4().hex}.wav"
            try:
                extract_audio(ffmpeg, inp, tmp_wav, logf=logf)
            except Exception as e:
                write_log(f"Audio extraction failed: {e}", logf)
                print(f"Audio extraction failed: {e}")
                sys.exit(1)

            try:
                model = load_model(model_dir)
                results = recognize_wav(model, tmp_wav, phrase_bias=phrase_bias, logf=logf)
            except Exception as e:
                write_log(f"Transcription failed: {e}", logf)
                print(f"Transcription failed: {e}")
                if tmp_wav.exists() and not args.keep_wav:
                    tmp_wav.unlink()
                sys.exit(1)

            txt_out = Path(args.txt_out) if args.txt_out else OUT_DIR / (inp.stem + ".txt")
            srt_out = Path(args.srt_out) if args.srt_out else OUT_DIR / (inp.stem + ".srt")
            save_txt_transcript(results, txt_out)
            save_srt_transcript(results, srt_out)

            write_log(f"Transcript TXT: {txt_out}", logf)
            write_log(f"Subtitles SRT: {srt_out}", logf)
            if not args.keep_wav and tmp_wav.exists():
                tmp_wav.unlink()

            print(json.dumps({"txt": str(txt_out), "srt": str(srt_out)}, ensure_ascii=False))

        elif args.cmd == "export":
            inp = Path(args.inp)
            srtp = Path(args.srt)
            outp = Path(args.out)
            if not inp.exists() or not srtp.exists():
                write_log("Input video or SRT not found.", logf)
                print("Input video or SRT not found.")
                sys.exit(1)

            try:
                if args.mode == "softsubs":
                    mux_soft_subs(ffmpeg, inp, srtp, outp, logf=logf)
                elif args.mode == "burn":
                    burn_subs(ffmpeg, inp, srtp, outp, logf=logf)
                elif args.mode == "audio":
                    export_audio_only(ffmpeg, inp, outp, audio_codec=args.audio_codec, logf=logf)
            except Exception as e:
                write_log(f"Export failed: {e}", logf)
                print(f"Export failed: {e}")
                sys.exit(1)
            write_log(f"Exported: {outp}", logf)
            print(str(outp))

        elif args.cmd == "models":
            ms = list_models()
            if not ms:
                print("No models found under ./models")
            else:
                for m in ms:
                    print(m)

        elif args.cmd == "prepare-corpus":
            inp = Path(args.inp)
            outp = Path(args.out)
            if not inp.exists():
                write_log("Input corpus directory not found.", logf)
                print("Input corpus directory not found.")
                sys.exit(1)
            try:
                man = prepare_wav_corpus(ffmpeg, inp, outp)
            except Exception as e:
                write_log(f"Corpus preparation failed: {e}", logf)
                print(f"Corpus preparation failed: {e}")
                sys.exit(1)
            write_log(f"Corpus manifest: {man}", logf)
            print(str(man))

        elif args.cmd == "train":
            corpus = Path(args.corpus)
            outp = Path(args.out)
            if not corpus.exists():
                write_log("Corpus manifest not found.", logf)
                print("Corpus manifest not found.")
                sys.exit(1)
            # If outp is relative, place under ./models
            if not outp.is_absolute():
                outp = MODELS_DIR / outp
            outp.parent.mkdir(parents=True, exist_ok=True)
            try:
                model_dir = launch_training(corpus, outp, logf=logf)
            except Exception as e:
                write_log(f"Training launcher failed: {e}", logf)
                print(f"Training launcher failed: {e}")
                sys.exit(1)
            write_log(f"New model ready in {model_dir}", logf)
            print(str(model_dir))

if __name__ == "__main__":
    main()
"@ | Out-File -FilePath $appFile -Encoding UTF8

Write-Host "=== Deployment Complete ==="
Write-Host "Directory structure:"
Get-ChildItem $baseDir

Write-Host "`nVerification:"
# Quick checks
if (Test-Path (Join-Path $binDir "ffmpeg.exe")) {
    Write-Host "ffmpeg.exe present."
} else {
    Write-Host "ffmpeg.exe missing; please verify extraction under bin/."
}
$smallModel = Get-ChildItem $modelsDir -Directory | Where-Object { $_.Name -like "vosk-model-small-en-us-0.15*" } | Select-Object -First 1
$largeModel = Get-ChildItem $modelsDir -Directory | Where-Object { $_.Name -like "vosk-model-en-us-0.22*" } | Select-Object -First 1
if ($smallModel) { Write-Host "Small model present: $($smallModel.Name)" } else { Write-Host "Small model missing." }
if ($largeModel) { Write-Host "Large model present: $($largeModel.Name)" } else { Write-Host "Large model missing." }
if (Test-Path $voskWheelFile) { Write-Host "Vosk wheel present: $voskWheelFile" } else { Write-Host "Vosk wheel missing." }

Write-Host "`nNext steps:"
Write-Host "1. Ensure Python is installed and accessible."
Write-Host "2. Record: $PythonPath app.py record --duration 10"
Write-Host "3. Transcribe: $PythonPath app.py transcribe --in out/<video>.mp4"
Write-Host "4. Export (soft subs): $PythonPath app.py export --in out/<video>.mp4 --srt out/<video>.srt --mode softsubs --out out/<video>_subs.mp4"