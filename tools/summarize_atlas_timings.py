#!/usr/bin/env python3
"""Summarize sampled atlas diagnostics; these are not physical presentation times."""
import argparse
import json
import math
import re
import statistics
from pathlib import Path


def distribution(values):
    values = sorted(values)
    if not values:
        return {"n": 0}
    return {
        "n": len(values), "min": values[0], "median": statistics.median(values),
        "p95": values[math.ceil(len(values) * .95) - 1], "max": values[-1],
    }


def summarize(source, receiver, first_frame):
    result = {"first_frame": first_frame, "units": "microseconds",
              "physical_present_receipt": False}
    for prefix, text, fields in [
        ("atlas-source-timing", source, ["encode_us", "previous_feedback_wait_us",
          "capture_to_encode_start_us", "capture_to_batch_return_us"]),
        ("atlas-wire-timing", source, ["feedback_us", "total_us"]),
        ("atlas-receiver-timing", receiver, ["record_us", "write_us", "receipt_us"]),
    ]:
        rows = [dict(re.findall(r"(\w+)=(-?\d+)\b", line))
                for line in text.splitlines() if line.startswith(prefix + " ")]
        rows = [row for row in rows if int(row["frame"]) >= first_frame]
        for field in fields:
            result[prefix + "." + field] = distribution(
                [int(row[field]) for row in rows if field in row])
    phases = {}
    for frame, phase, remaining in re.findall(
        r"atlas-native-timing frame=(\d+) phase=([\w-]+) remaining_us=(-?\d+)", receiver
    ):
        if int(frame) >= first_frame:
            phases.setdefault(int(frame), {})[phase] = int(remaining)
    for before, after in [("pipe-admission", "decoded"), ("decoded", "proxy-ready"),
                          ("proxy-ready", "copy-ready"), ("copy-ready", "committed"),
                          ("pipe-admission", "committed")]:
        result[before + "->" + after] = distribution(
            [row[before] - row[after] for row in phases.values()
             if before in row and after in row])
    result["native_samples"] = sum("committed" in row for row in phases.values())
    result["native_samples_missed"] = sum(row.get("committed", 0) < 0 for row in phases.values())
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("receiver", type=Path)
    parser.add_argument("--first-frame", type=int, default=30,
                        help="Exclude startup frames; diagnostics are sampled, not every frame")
    args = parser.parse_args()
    print(json.dumps(summarize(args.source.read_text(), args.receiver.read_text(),
                               args.first_frame), indent=2))
