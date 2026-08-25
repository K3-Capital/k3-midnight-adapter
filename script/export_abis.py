#!/usr/bin/env python3
"""Export and verify the release ABI surface deterministically.

The checked JSON files are intentionally limited to the three deployable
contracts.  ABI entries are sorted by their canonical shape and serialized with
stable JSON formatting so a clean rebuild produces byte-identical artifacts.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
ABI_DIR = ROOT / "docs" / "abi"
CONTRACTS = (
    "BlueMidnightAdapter",
    "BlueMidnightAdapterFactory",
    "PolicySetterRatifier",
)
OPERATOR_VIEWS: dict[str, tuple[str, ...]] = {
    "BlueMidnightAdapter": (
        "realAssets",
        "expectedSupplyAssets",
        "blueAvailableLiquidity",
        "buyerAssetsBound",
        "marketAccounting",
        "activeMarketIdsLength",
        "activeMarketIdAt",
    ),
}


def canonical_type(item: dict[str, Any]) -> str:
    if item.get("type") != "tuple" and item.get("type") != "tuple[]":
        return str(item.get("type", ""))
    components = item.get("components", [])
    suffix = "[]" if item["type"] == "tuple[]" else ""
    return "(" + ",".join(canonical_type(component) for component in components) + ")" + suffix


def entry_key(item: dict[str, Any]) -> tuple[str, str, tuple[str, ...], str]:
    inputs = tuple(canonical_type(value) for value in item.get("inputs", []))
    return (str(item.get("type", "")), str(item.get("name", "")), inputs, json.dumps(item, sort_keys=True))


def normalized_abi(contract: str) -> list[dict[str, Any]]:
    command = ["forge", "inspect", contract, "abi", "--json"]
    try:
        result = subprocess.run(command, cwd=ROOT, check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        raise RuntimeError(f"unable to inspect {contract}: {detail.strip()}") from exc
    abi = json.loads(result.stdout)
    if not isinstance(abi, list):
        raise RuntimeError(f"forge returned a non-array ABI for {contract}")
    return sorted(abi, key=entry_key)


def render(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


def validate(abis: dict[str, list[dict[str, Any]]]) -> None:
    for contract, required_names in OPERATOR_VIEWS.items():
        available = {
            item["name"]
            for item in abis[contract]
            if item.get("type") == "function" and item.get("stateMutability") in {"view", "pure"}
        }
        missing = sorted(set(required_names) - available)
        if missing:
            raise RuntimeError(f"{contract} is missing required operator views: {', '.join(missing)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="rewrite checked ABI artifacts")
    parser.add_argument("--check", action="store_true", help="verify checked artifacts (the default)")
    args = parser.parse_args()
    if args.write and args.check:
        parser.error("choose --write or --check, not both")

    # Build first so the export always reflects the current Solidity sources.
    subprocess.run(["forge", "build", "--skip", "test"], cwd=ROOT, check=True)
    abis = {contract: normalized_abi(contract) for contract in CONTRACTS}
    validate(abis)
    expected = {f"{contract}.json": render(abis[contract]) for contract in CONTRACTS}
    expected["operator-views.json"] = render({name: list(views) for name, views in OPERATOR_VIEWS.items()})

    if args.write:
        ABI_DIR.mkdir(parents=True, exist_ok=True)
        for filename, content in expected.items():
            (ABI_DIR / filename).write_text(content, encoding="utf-8")
        print(f"exported {len(expected)} deterministic ABI artifacts to {ABI_DIR.relative_to(ROOT)}")
        return 0

    failures: list[str] = []
    for filename, content in expected.items():
        path = ABI_DIR / filename
        if not path.exists():
            failures.append(f"missing {path.relative_to(ROOT)}")
        elif path.read_text(encoding="utf-8") != content:
            failures.append(f"outdated {path.relative_to(ROOT)} (run --write)")
    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    print(f"verified {len(expected)} deterministic ABI artifacts; operator views present")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (json.JSONDecodeError, RuntimeError) as exc:
        print(f"ABI export failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
