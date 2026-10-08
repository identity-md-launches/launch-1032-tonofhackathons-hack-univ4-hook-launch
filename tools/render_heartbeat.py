#!/usr/bin/env python3
"""Render the fixed request once after deployment; performs no network or transaction calls."""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def render(consumer, deployment_block):
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", consumer) or int(consumer, 16) in (0, 0xDEAD):
        raise ValueError("consumer must be the deployed hook address")
    if deployment_block < 1 or deployment_block >= 2**53 - 1:
        raise ValueError("deployment block must be a positive JSON-safe integer")
    body = json.loads((ROOT / "docs/heartbeat.json").read_text())
    body["consumer"]["verifyingContract"] = consumer.lower()
    body["window"] = {"fromBlock": deployment_block, "toBlock": deployment_block + 1}
    return body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--consumer", required=True)
    parser.add_argument("--deployment-block", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--schedule-output", type=Path)
    parser.add_argument("--runs", type=int)
    args = parser.parse_args()
    if args.schedule_output and (args.runs is None or not 1 <= args.runs <= 1_000_000):
        parser.error("--schedule-output requires --runs in [1, 1000000]")
    body = render(args.consumer, args.deployment_block)
    args.output.write_text(json.dumps(body, ensure_ascii=False, separators=(",", ":")) + "\n")
    if args.schedule_output:
        schedule = json.loads((ROOT / "docs/schedule.json").read_text())
        schedule["input"] = body
        schedule["runs"] = args.runs
        args.schedule_output.write_text(json.dumps(schedule, ensure_ascii=False, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
