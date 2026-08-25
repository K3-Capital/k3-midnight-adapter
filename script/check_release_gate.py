#!/usr/bin/env python3
"""Build with the release profile and enforce deployable bytecode limits."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EIP170_LIMIT = 24_576
ADAPTER_LIMIT = 20_000
DEPLOYABLE = ("BlueMidnightAdapter", "PolicySetterRatifier")


def build() -> None:
    env = os.environ.copy()
    env["FOUNDRY_PROFILE"] = "deployment"
    subprocess.run(["forge", "build", "--skip", "test"], cwd=ROOT, env=env, check=True)


def byte_length(artifact: Path, field: str) -> int:
    value = json.loads(artifact.read_text(encoding="utf-8"))[field]["object"]
    if not isinstance(value, str) or not value.startswith("0x"):
        raise RuntimeError(f"{artifact.relative_to(ROOT)} has invalid {field}")
    return (len(value) - 2) // 2


def main() -> int:
    build()
    failures: list[str] = []
    report: list[str] = []
    for contract in DEPLOYABLE:
        artifact = ROOT / "out" / f"{contract}.sol" / f"{contract}.json"
        if not artifact.exists():
            failures.append(f"missing artifact: {artifact.relative_to(ROOT)}")
            continue
        runtime = byte_length(artifact, "deployedBytecode")
        creation = byte_length(artifact, "bytecode")
        report.append(f"{contract}: runtime={runtime} creation={creation}")
        if runtime >= EIP170_LIMIT:
            failures.append(f"{contract} runtime {runtime} >= EIP-170 limit {EIP170_LIMIT}")
        if contract == "BlueMidnightAdapter" and runtime >= ADAPTER_LIMIT:
            failures.append(f"{contract} runtime {runtime} >= release limit {ADAPTER_LIMIT}")

    print("release profile: deployment (optimizer=true, runs=200, via_ir=true, evm=osaka)")
    print("\n".join(report))
    if failures:
        print("release gate failed:", file=sys.stderr)
        print("\n".join(f"- {failure}" for failure in failures), file=sys.stderr)
        return 1
    print(f"release gate passed: all {len(DEPLOYABLE)} deployable contracts are below EIP-170")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
