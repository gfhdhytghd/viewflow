#!/usr/bin/env python3
"""Summarize fixture markers observed through DXGI desktop duplication.

These are desktop-present observations, not panel photon receipts. Sampling
may miss changes; do not use this alone to claim the complete latency target.
"""
import argparse
import bisect
import collections
import json
import math
import re
import statistics
from pathlib import Path


def distribution(values):
    ordered = sorted(values)
    if not ordered:
        return {"n": 0}
    return {"n": len(ordered), "min": ordered[0],
            "median": statistics.median(ordered),
            "p95": ordered[math.ceil(len(ordered) * .95) - 1], "max": ordered[-1]}


def summarize(text):
    frequency = re.search(r"qpc_frequency=(\d+)", text)
    if not frequency or not int(frequency[1]):
        raise ValueError("missing QPC frequency")
    frequency = int(frequency[1])
    rows = [dict((key, int(value)) for key, value in re.findall(r"(\w+)=(\d+)", line))
            for line in text.splitlines() if line.startswith("desktop-marker ")]
    valid = [row for row in rows if row["present_qpc"] > 0]
    pairs = list(zip(valid, valid[1:]))
    elapsed = (valid[-1]["present_qpc"] - valid[0]["present_qpc"]) / frequency if len(valid) > 1 else 0
    return {
        "desktop_present_not_photon": True,
        "end_to_end_latency_verified": False,
        "observed_changes": len(rows), "positive_present_timestamps": len(valid),
        "elapsed_seconds": elapsed,
        "observed_changes_per_second": (len(valid) - 1) / elapsed if elapsed > 0 else None,
        "nonincreasing_present_timestamps": sum(b["present_qpc"] <= a["present_qpc"] for a, b in pairs),
        "nonincreasing_frame_ids": sum(b["frame"] <= a["frame"] for a, b in pairs),
        "desktop_change_gap_ms": distribution([(b["present_qpc"] - a["present_qpc"]) * 1000 / frequency for a, b in pairs]),
        "producer_frame_step": distribution([b["frame"] - a["frame"] for a, b in pairs]),
        "present_to_observation_ms": distribution([(r["observed_qpc"] - r["present_qpc"]) * 1000 / frequency for r in valid]),
        "accumulated_desktop_frames": distribution([r["accumulated"] for r in valid]),
        "acquire_us": distribution([r["acquire_us"] for r in valid if "acquire_us" in r]),
        "copy_map_us": distribution([r["copy_map_us"] for r in valid if "copy_map_us" in r]),
    }


def latency_bounds(desktop, source, fixture, receiver):
    frequency = int(re.search(r"qpc_frequency=(\d+)", desktop)[1])
    def rows(text, prefix):
        return [dict((key, int(value)) for key, value in re.findall(r"(\w+)=(-?\d+)", line))
                for line in text.splitlines() if line.startswith(prefix)]
    anchors = rows(receiver, "atlas-receiver-clock-anchor ")
    if len(anchors) != 1:
        raise ValueError("exactly one receiver elapsed-clock/QPC anchor is required")
    anchor = anchors[0]
    if anchor["frequency"] != frequency or anchor["before_ns"] > anchor["after_ns"]:
        raise ValueError("invalid receiver clock anchor")
    frames = {r["frame"]: r for r in rows(fixture, "fixture-render ")}
    clocks = sorted(rows(source, "atlas-clock-mapping "), key=lambda r: r["source_ns"])
    times = [r["source_ns"] for r in clocks]
    captures = collections.defaultdict(list)
    for captured in rows(source, "GPU fixture-marker "):
        if captured["valid"]:
            captures[captured["marker_frame"]].append(captured)
    mutations = {r["frame"]: r for r in rows(receiver, "atlas-native-mutation ")}
    completions = collections.defaultdict(list)
    for probe in rows(receiver, "atlas-gpu-copy-completion "):
        completions[probe["frame"]].append(probe)
    gpu_lower, gpu_upper, gpu_to_desktop_lower, gpu_to_desktop_upper = [], [], [], []
    missing_gpu = invalid_gpu = 0
    producer_age, capture_lower, capture_upper = [], [], []
    mutation_lower, mutation_upper, mutation_to_desktop = [], [], []
    missing_capture = ambiguous_capture = missing_mutation = 0
    lower, upper, uncertainty = [], [], []
    missing_frame = missing_clock = stale_clock = 0
    for observed in rows(desktop, "desktop-marker "):
        if observed["present_qpc"] <= 0:
            continue
        frame = frames.get(observed["frame"])
        if frame is None:
            missing_frame += 1
            continue
        index = bisect.bisect_right(times, frame["time_ns"]) - 1
        if index < 0:
            missing_clock += 1
            continue
        clock = clocks[index]
        if frame["time_ns"] > clock["source_ns"] + clock["valid_remaining_ns"]:
            stale_clock += 1
            continue
        ticks = (observed["present_qpc"] - anchor["qpc"]) * 1_000_000_000
        present_lower = anchor["before_ns"] + ticks // frequency
        present_upper = anchor["after_ns"] + (ticks + frequency - 1) // frequency
        midpoint = frame["time_ns"] + clock["remote_offset_ns"]
        error = clock["uncertainty_ns"]
        lower.append((present_lower - midpoint - error) / 1_000_000)
        upper.append((present_upper - midpoint + error) / 1_000_000)
        uncertainty.append(error / 1_000_000)
        candidates = captures[observed["frame"]]
        if not candidates:
            missing_capture += 1
            continue
        if len(candidates) != 1:
            ambiguous_capture += 1
            continue
        captured = candidates[0]
        capture_ns = captured["captured_ns"]
        capture_index = bisect.bisect_right(times, capture_ns) - 1
        if capture_index < 0:
            continue
        capture_clock = clocks[capture_index]
        if capture_ns > capture_clock["source_ns"] + capture_clock["valid_remaining_ns"]:
            continue
        capture_midpoint = capture_ns + capture_clock["remote_offset_ns"]
        capture_error = capture_clock["uncertainty_ns"]
        producer_age.append((capture_ns - frame["time_ns"]) / 1_000_000)
        capture_lower.append((present_lower - capture_midpoint - capture_error) / 1_000_000)
        capture_upper.append((present_upper - capture_midpoint + capture_error) / 1_000_000)
        mutation = mutations.get(captured["atlas_frame"])
        if mutation is None:
            missing_mutation += 1
            continue
        if mutation["frequency"] != frequency:
            raise ValueError("native mutation QPC frequency differs")
        mutation_delta = (mutation["qpc"] - anchor["qpc"]) * 1_000_000_000
        mutation_lower.append((anchor["before_ns"] + mutation_delta // frequency - capture_midpoint - capture_error) / 1_000_000)
        mutation_upper.append((anchor["after_ns"] + (mutation_delta + frequency - 1) // frequency - capture_midpoint + capture_error) / 1_000_000)
        mutation_to_desktop.append((observed["present_qpc"] - mutation["qpc"]) * 1000 / frequency)
        probes = completions.get(captured["atlas_frame"], [])
        if not probes:
            missing_gpu += 1
        elif len(probes) != 1 or probes[0]["status"] != 0 or not (
                probes[0]["submitted_qpc"] <= probes[0]["lower_qpc"] <= probes[0]["upper_qpc"]):
            invalid_gpu += 1
        else:
            probe = probes[0]
            gpu_lower.append((probe["lower_qpc"] - probe["submitted_qpc"]) * 1000 / frequency)
            gpu_upper.append((probe["upper_qpc"] - probe["submitted_qpc"]) * 1000 / frequency)
            gpu_to_desktop_lower.append((observed["present_qpc"] - probe["upper_qpc"]) * 1000 / frequency)
            gpu_to_desktop_upper.append((observed["present_qpc"] - probe["lower_qpc"]) * 1000 / frequency)
    return {
        "start": "fixture pre-draw CLOCK_MONOTONIC timestamp",
        "end": "DXGI desktop LastPresentTime QPC timestamp",
        "clock_model": "existing paired QUIC minimum-RTT four-timestamp estimate and uncertainty",
        "input_to_photon_measured": False,
        "receiver_anchor_interval_ns": anchor["after_ns"] - anchor["before_ns"],
        "missing_fixture_frame": missing_frame, "missing_preceding_clock": missing_clock,
        "expired_clock_mapping": stale_clock,
        "latency_lower_ms": distribution(lower), "latency_upper_ms": distribution(upper),
        "clock_uncertainty_ms": distribution(uncertainty),
        "definitely_over_two_60hz_frames": sum(value > 1000 / 30 for value in lower),
        "definitely_within_two_60hz_frames": sum(value <= 1000 / 30 for value in upper),
        "negative_upper_bound": sum(value < 0 for value in upper),
        "unique_capture_stage_samples": {
            "missing_capture_marker": missing_capture, "ambiguous_repeated_marker": ambiguous_capture,
            "missing_native_mutation": missing_mutation,
            "render_to_capture_ms": distribution(producer_age),
            "capture_to_desktop_lower_ms": distribution(capture_lower),
            "capture_to_desktop_upper_ms": distribution(capture_upper),
            "capture_to_mutation_lower_ms": distribution(mutation_lower),
            "capture_to_mutation_upper_ms": distribution(mutation_upper),
            "mutation_to_desktop_ms": distribution(mutation_to_desktop),
            "negative_mutation_to_desktop": sum(value < 0 for value in mutation_to_desktop),
            "gpu_copy_completion_bounds": {
                "scope": "event after composition surface copy on application's D3D queue; polling bounds, not DWM completion",
                "missing": missing_gpu, "invalid_or_multiple": invalid_gpu,
                "submitted_to_complete_lower_ms": distribution(gpu_lower),
                "submitted_to_complete_upper_ms": distribution(gpu_upper),
                "complete_to_desktop_lower_ms": distribution(gpu_to_desktop_lower),
                "complete_to_desktop_upper_ms": distribution(gpu_to_desktop_upper),
                "ready_observed_before_desktop": sum(v >= 0 for v in gpu_to_desktop_lower),
            },
        },
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--source", type=Path, help="Source log with atlas-clock-mapping diagnostics")
    parser.add_argument("--fixture", type=Path, help="Matching owned fixture producer log")
    parser.add_argument("--receiver", type=Path, help="Receiver log with elapsed-clock/QPC anchor")
    args = parser.parse_args()
    if sum(bool(value) for value in (args.source, args.fixture, args.receiver)) not in (0, 3):
        parser.error("--source, --fixture and --receiver must be supplied together")
    desktop = args.log.read_text()
    result = summarize(desktop)
    if args.source:
        result["render_to_desktop"] = latency_bounds(desktop, args.source.read_text(), args.fixture.read_text(), args.receiver.read_text())
    print(json.dumps(result, indent=2))
