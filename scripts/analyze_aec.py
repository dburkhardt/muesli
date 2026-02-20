#!/usr/bin/env python3
"""
Offline AEC audio analysis tool for Muesli.

Computes cross-correlation lag and ERLE estimate from render (system audio)
and capture (microphone) CAF files to diagnose AEC convergence issues.

Usage:
    python3 analyze_aec.py --render audio.caf --capture microphone.caf [--output /tmp/aec_analysis_results/]
"""

import argparse
import json
import math
import os
import struct
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False

try:
    from scipy import signal as scipy_signal
    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False

try:
    import soundfile as sf
    HAS_SOUNDFILE = True
except ImportError:
    HAS_SOUNDFILE = False


def read_audio_file(path: str) -> tuple:
    """
    Read an audio file (CAF or WAV). Returns (sample_rate, num_channels, samples_array, num_frames).
    Uses soundfile if available (reads CAF directly), otherwise falls back to afconvert + struct.
    """
    if HAS_SOUNDFILE:
        data, sr = sf.read(path, dtype="float32", always_2d=True)
        if HAS_NUMPY:
            return sr, data.shape[1], data, data.shape[0]
        else:
            # Convert to list for non-numpy path
            return sr, data.shape[1], data.tolist(), data.shape[0]

    # Fallback: convert CAF to WAV with afconvert, then read with struct
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=True) as tmp:
        wav_path = tmp.name

    result = subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", "LEF32@48000", path, wav_path],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"afconvert failed for {path}: {result.stderr}")

    try:
        sr, ch, samples, num_frames = _read_wav_float32_struct(wav_path)
    finally:
        if os.path.exists(wav_path):
            os.unlink(wav_path)

    return sr, ch, samples, num_frames


def _read_wav_float32_struct(wav_path: str) -> tuple:
    """Read a WAV file with Float32 data using struct (no external dependencies)."""
    with open(wav_path, "rb") as f:
        riff = f.read(4)
        if riff != b"RIFF":
            raise ValueError(f"Not a RIFF file: {wav_path}")
        f.read(4)  # file size
        wave = f.read(4)
        if wave != b"WAVE":
            raise ValueError(f"Not a WAVE file: {wav_path}")

        fmt_found = False
        sample_rate = 0
        num_channels = 0
        audio_data = b""

        while True:
            chunk_header = f.read(8)
            if len(chunk_header) < 8:
                break
            chunk_id = chunk_header[:4]
            chunk_size = struct.unpack("<I", chunk_header[4:8])[0]

            if chunk_id == b"fmt ":
                fmt_data = f.read(chunk_size)
                audio_format = struct.unpack("<H", fmt_data[0:2])[0]
                num_channels = struct.unpack("<H", fmt_data[2:4])[0]
                sample_rate = struct.unpack("<I", fmt_data[4:8])[0]
                bits_per_sample = struct.unpack("<H", fmt_data[14:16])[0]
                # Accept IEEE Float (3) or WAVE_FORMAT_EXTENSIBLE (65534) with float subformat
                if audio_format == 65534:
                    # WAVE_FORMAT_EXTENSIBLE: check sub-format GUID at offset 24
                    if chunk_size >= 40:
                        sub_format = struct.unpack("<H", fmt_data[24:26])[0]
                        if sub_format != 3:
                            raise ValueError(f"Extensible format sub-type {sub_format} is not IEEE Float")
                elif audio_format != 3:
                    raise ValueError(f"Expected IEEE Float format (3), got {audio_format}")
                if bits_per_sample != 32:
                    raise ValueError(f"Expected 32-bit, got {bits_per_sample}-bit")
                fmt_found = True
            elif chunk_id == b"data":
                audio_data = f.read(chunk_size)
            else:
                f.read(chunk_size)
            if chunk_size % 2 != 0:
                f.read(1)

        if not fmt_found:
            raise ValueError("No fmt chunk found in WAV file")

        num_frames = len(audio_data) // (4 * num_channels)

        if HAS_NUMPY:
            samples = np.frombuffer(audio_data, dtype=np.float32)
            samples = samples.reshape(-1, num_channels)
        else:
            floats = [s[0] for s in struct.iter_unpack("<f", audio_data)]
            # Group into frames
            samples = []
            for i in range(0, len(floats), num_channels):
                samples.append(floats[i:i + num_channels])

        return sample_rate, num_channels, samples, num_frames


def downmix_to_mono(samples, num_channels: int):
    """Downmix multi-channel audio to mono by averaging channels."""
    if HAS_NUMPY:
        arr = np.asarray(samples, dtype=np.float64)
        if arr.ndim == 2 and arr.shape[1] > 1:
            return np.mean(arr, axis=1)
        return arr.flatten()
    else:
        if num_channels == 1:
            return [row[0] if isinstance(row, (list, tuple)) else row for row in samples]
        return [sum(row) / num_channels for row in samples]


def compute_rms(samples) -> float:
    """Compute RMS of audio samples."""
    if HAS_NUMPY:
        arr = np.asarray(samples, dtype=np.float64)
        return float(np.sqrt(np.mean(arr ** 2)))
    else:
        n = len(samples)
        if n == 0:
            return 0.0
        sq_sum = sum(s * s for s in samples)
        return (sq_sum / n) ** 0.5


def compute_cross_correlation_lag(render_mono, capture_mono, sample_rate: int, max_lag_ms: float = 500.0):
    """
    Compute cross-correlation between render and capture to find acoustic delay.
    Returns lag in milliseconds and the correlation coefficient at that lag.
    """
    max_lag_samples = int(max_lag_ms / 1000.0 * sample_rate)

    if HAS_NUMPY and HAS_SCIPY:
        render = np.asarray(render_mono, dtype=np.float64)
        capture = np.asarray(capture_mono, dtype=np.float64)

        min_len = min(len(render), len(capture))
        render = render[:min_len]
        capture = capture[:min_len]

        render_norm = render - np.mean(render)
        capture_norm = capture - np.mean(capture)

        correlation = scipy_signal.correlate(capture_norm, render_norm, mode="full")
        lags = scipy_signal.correlation_lags(len(capture_norm), len(render_norm), mode="full")

        # Restrict to plausible lags (0 to max_lag — capture lags render)
        valid = (lags >= 0) & (lags <= max_lag_samples)
        if not np.any(valid):
            return 0.0, 0.0

        valid_corr = correlation[valid]
        valid_lags = lags[valid]

        best_idx = np.argmax(np.abs(valid_corr))
        best_lag = int(valid_lags[best_idx])
        lag_ms = best_lag / sample_rate * 1000.0

        norm_factor = np.sqrt(np.sum(render_norm ** 2) * np.sum(capture_norm ** 2))
        corr_coeff = float(valid_corr[best_idx] / norm_factor) if norm_factor > 0 else 0.0

        return lag_ms, corr_coeff

    elif HAS_NUMPY:
        render = np.asarray(render_mono, dtype=np.float64)
        capture = np.asarray(capture_mono, dtype=np.float64)
        min_len = min(len(render), len(capture))
        render = render[:min_len]
        capture = capture[:min_len]

        # Downsample 8x for speed
        ds = 8
        render_ds = render[::ds] - np.mean(render[::ds])
        capture_ds = capture[::ds] - np.mean(capture[::ds])

        max_lag_ds = max_lag_samples // ds
        best_lag_ds = 0
        best_val = 0.0
        for lag in range(0, max_lag_ds + 1):
            if lag >= len(capture_ds):
                break
            c = np.dot(capture_ds[lag:], render_ds[:len(capture_ds) - lag])
            if abs(c) > abs(best_val):
                best_val = c
                best_lag_ds = lag

        lag_ms = (best_lag_ds * ds) / sample_rate * 1000.0
        norm_factor = np.sqrt(np.sum(render_ds ** 2) * np.sum(capture_ds ** 2))
        corr_coeff = float(best_val / norm_factor) if norm_factor > 0 else 0.0
        return lag_ms, corr_coeff

    else:
        print("WARNING: No numpy/scipy — cross-correlation will be very slow", file=sys.stderr)
        min_len = min(len(render_mono), len(capture_mono))
        window = min(min_len, sample_rate * 5)
        r = render_mono[:window]
        c = capture_mono[:window]
        max_lag_s = min(max_lag_samples, window // 2)

        best_lag = 0
        best_val = 0.0
        for lag in range(0, max_lag_s, 48):  # step by 1ms
            val = sum(c[lag + i] * r[i] for i in range(min(window - lag, len(r))))
            if abs(val) > abs(best_val):
                best_val = val
                best_lag = lag

        lag_ms = best_lag / sample_rate * 1000.0
        return lag_ms, 0.0


def compute_erle(render_mono, capture_mono, sample_rate: int,
                 window_ms: float = 500.0, render_threshold: float = 0.001):
    """
    Compute ERLE (Echo Return Loss Enhancement) estimate.

    For windows where render RMS > threshold (indicating far-end speech),
    compute 10*log10(render_rms / capture_rms) as an ERLE proxy.

    Returns (erle_values, median_erle, mean_erle, window_details).
    """
    window_samples = int(window_ms / 1000.0 * sample_rate)

    if HAS_NUMPY:
        render = np.asarray(render_mono, dtype=np.float64)
        capture = np.asarray(capture_mono, dtype=np.float64)
    else:
        render = render_mono
        capture = capture_mono

    min_len = min(len(render), len(capture))
    num_windows = min_len // window_samples

    erle_values = []
    window_details = []

    for i in range(num_windows):
        start = i * window_samples
        end = start + window_samples

        if HAS_NUMPY:
            r_rms = float(np.sqrt(np.mean(render[start:end] ** 2)))
            c_rms = float(np.sqrt(np.mean(capture[start:end] ** 2)))
        else:
            r_rms = compute_rms(render[start:end])
            c_rms = compute_rms(capture[start:end])

        if r_rms > render_threshold:
            if c_rms > 1e-10:
                erle_db = 10.0 * math.log10(r_rms / c_rms)
            else:
                erle_db = 60.0  # Cap at 60 dB for near-silent capture
            erle_values.append(erle_db)
            window_details.append({
                "window_idx": i,
                "time_s": round(start / sample_rate, 2),
                "render_rms": round(r_rms, 6),
                "capture_rms": round(c_rms, 6),
                "erle_db": round(erle_db, 2),
            })

    if not erle_values:
        return [], 0.0, 0.0, window_details

    if HAS_NUMPY:
        median_erle = float(np.median(erle_values))
        mean_erle = float(np.mean(erle_values))
    else:
        sorted_vals = sorted(erle_values)
        n = len(sorted_vals)
        median_erle = (sorted_vals[n // 2 - 1] + sorted_vals[n // 2]) / 2.0 if n % 2 == 0 else sorted_vals[n // 2]
        mean_erle = sum(erle_values) / n

    return erle_values, median_erle, mean_erle, window_details


def analyze_session(render_path: str, capture_path: str) -> dict:
    """Run full analysis on a render/capture pair."""
    print(f"  Reading render audio...")
    r_sr, r_ch, r_samples, r_num_frames = read_audio_file(render_path)
    print(f"    {r_sr} Hz, {r_ch} ch, {r_num_frames} frames ({r_num_frames / r_sr:.2f}s)")

    print(f"  Reading capture audio...")
    c_sr, c_ch, c_samples, c_num_frames = read_audio_file(capture_path)
    print(f"    {c_sr} Hz, {c_ch} ch, {c_num_frames} frames ({c_num_frames / c_sr:.2f}s)")

    # Downmix to mono
    print(f"  Downmixing to mono...")
    render_mono = downmix_to_mono(r_samples, r_ch)
    capture_mono = downmix_to_mono(c_samples, c_ch)

    # Overall RMS
    render_rms = compute_rms(render_mono)
    capture_rms = compute_rms(capture_mono)
    print(f"  Render RMS:  {render_rms:.6f}")
    print(f"  Capture RMS: {capture_rms:.6f}")

    # Cross-correlation
    print(f"  Computing cross-correlation...")
    lag_ms, corr_coeff = compute_cross_correlation_lag(render_mono, capture_mono, r_sr)
    print(f"  Lag: {lag_ms:.2f} ms (correlation: {corr_coeff:.4f})")

    # ERLE
    print(f"  Computing ERLE estimate (500ms windows)...")
    erle_values, median_erle, mean_erle, window_details = compute_erle(
        render_mono, capture_mono, r_sr
    )
    active_windows = len(erle_values)
    total_windows = min(len(render_mono), len(capture_mono)) // int(0.5 * r_sr)
    print(f"  Active windows: {active_windows}/{total_windows}")
    print(f"  Median ERLE: {median_erle:.2f} dB")
    print(f"  Mean ERLE:   {mean_erle:.2f} dB")

    return {
        "render_file": render_path,
        "capture_file": capture_path,
        "render_sample_rate": r_sr,
        "render_channels": r_ch,
        "render_frames": r_num_frames,
        "render_duration_s": round(r_num_frames / r_sr, 3),
        "capture_sample_rate": c_sr,
        "capture_channels": c_ch,
        "capture_frames": c_num_frames,
        "capture_duration_s": round(c_num_frames / c_sr, 3),
        "render_rms": round(render_rms, 6),
        "capture_rms": round(capture_rms, 6),
        "lag_ms": round(lag_ms, 2),
        "correlation_coefficient": round(corr_coeff, 4),
        "erle_db_estimate_median": round(median_erle, 2),
        "erle_db_estimate_mean": round(mean_erle, 2),
        "erle_active_windows": active_windows,
        "erle_total_windows": total_windows,
        "erle_window_details": window_details,
        "analysis_timestamp": datetime.now(timezone.utc).isoformat(),
        "numpy_available": HAS_NUMPY,
        "scipy_available": HAS_SCIPY,
        "soundfile_available": HAS_SOUNDFILE,
    }


def print_summary(result: dict, label: str = "") -> None:
    """Print a human-readable summary of analysis results."""
    print()
    print("=" * 70)
    if label:
        print(f"  {label}")
        print("=" * 70)
    print(f"  Render:  {result['render_file']}")
    print(f"  Capture: {result['capture_file']}")
    print("-" * 70)
    print(f"  Render:  {result['render_duration_s']:.1f}s, {result['render_channels']}ch, "
          f"{result['render_sample_rate']}Hz, RMS={result['render_rms']:.6f}")
    print(f"  Capture: {result['capture_duration_s']:.1f}s, {result['capture_channels']}ch, "
          f"{result['capture_sample_rate']}Hz, RMS={result['capture_rms']:.6f}")
    print("-" * 70)
    print(f"  Cross-correlation lag: {result['lag_ms']:.2f} ms")
    print(f"  Correlation coeff:     {result['correlation_coefficient']:.4f}")
    print("-" * 70)
    print(f"  ERLE estimate (median): {result['erle_db_estimate_median']:.2f} dB")
    print(f"  ERLE estimate (mean):   {result['erle_db_estimate_mean']:.2f} dB")
    print(f"  Active windows:         {result['erle_active_windows']}/{result['erle_total_windows']}")
    print("-" * 70)

    erle = result["erle_db_estimate_median"]
    lag = result["lag_ms"]
    corr = result["correlation_coefficient"]

    issues = []
    if erle < 2.0:
        issues.append(f"ERLE very low ({erle:.1f} dB < 2 dB) -- AEC likely NOT converging")
    elif erle < 6.0:
        issues.append(f"ERLE low ({erle:.1f} dB) -- AEC may be partially converging")

    if corr < 0.05:
        issues.append(f"Very low correlation ({corr:.4f}) -- signals may be unrelated or heavily delayed")
    elif corr < 0.1:
        issues.append(f"Low correlation ({corr:.4f}) -- weak echo path coupling")

    if lag > 200:
        issues.append(f"High lag ({lag:.1f} ms) -- may exceed AEC filter length")
    elif lag < 1.0 and corr > 0.1:
        issues.append(f"Very low lag ({lag:.1f} ms) -- check if delay estimation is correct")

    if issues:
        print("  DIAGNOSTICS:")
        for issue in issues:
            print(f"    - {issue}")
    else:
        print("  DIAGNOSTICS: No issues detected -- AEC appears healthy")

    print("=" * 70)
    print()


def main():
    parser = argparse.ArgumentParser(
        description="Offline AEC audio analysis for Muesli recordings. "
                    "Computes cross-correlation lag and ERLE estimate from "
                    "render (system audio) and capture (microphone) CAF files.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --render audio.caf --capture microphone.caf
  %(prog)s --render audio.caf --capture microphone.caf --output /tmp/results/
  %(prog)s --render session1/audio.caf --capture session1/microphone.caf --json-only
        """,
    )
    parser.add_argument("--render", required=True, help="Path to render/system audio CAF file")
    parser.add_argument("--capture", required=True, help="Path to capture/microphone CAF file")
    parser.add_argument("--output", default="/tmp/aec_analysis_results/",
                        help="Output directory for JSON results (default: /tmp/aec_analysis_results/)")
    parser.add_argument("--json-only", action="store_true",
                        help="Output JSON only (no human-readable summary)")

    args = parser.parse_args()

    if not os.path.isfile(args.render):
        print(f"ERROR: Render file not found: {args.render}", file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(args.capture):
        print(f"ERROR: Capture file not found: {args.capture}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(args.output, exist_ok=True)

    print(f"AEC Audio Analysis Tool")
    print(f"  numpy:     {'yes' if HAS_NUMPY else 'NO (fallback mode)'}")
    print(f"  scipy:     {'yes' if HAS_SCIPY else 'NO (using numpy-only correlation)'}")
    print(f"  soundfile: {'yes (direct CAF reading)' if HAS_SOUNDFILE else 'NO (using afconvert fallback)'}")
    print()

    print("Analyzing session...")
    result = analyze_session(args.render, args.capture)

    timestamp_str = datetime.now().strftime("%Y%m%d_%H%M%S")
    json_filename = f"aec_analysis_{timestamp_str}.json"
    json_path = os.path.join(args.output, json_filename)

    with open(json_path, "w") as f:
        json.dump(result, f, indent=2)
    print(f"\nJSON report saved to: {json_path}")

    if not args.json_only:
        print_summary(result)

    return result


if __name__ == "__main__":
    main()
