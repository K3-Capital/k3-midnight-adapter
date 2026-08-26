#!/usr/bin/env python3
"""Regression test for release-gate isolation from ambient Foundry settings."""

from __future__ import annotations

import os
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "script" / "check_release_gate.py"


class ReleaseGateEnvironmentTest(unittest.TestCase):
    def test_hostile_foundry_environment_cannot_change_reported_profile_or_size(self) -> None:
        env = os.environ.copy()
        env.update(
            {
                "FOUNDRY_OPTIMIZER_RUNS": "1",
                "FOUNDRY_VIA_IR": "false",
                "FOUNDRY_EVM_VERSION": "paris",
                "DAPP_TEST_FUZZ_RUNS": "1",
            }
        )
        result = subprocess.run(
            ["python3", str(GATE)], cwd=ROOT, env=env, check=True, capture_output=True, text=True
        )
        self.assertIn("optimizer=true, runs=200, via_ir=true, evm=osaka", result.stdout)
        self.assertIn("BlueMidnightAdapter: runtime=17251 creation=21130", result.stdout)
        self.assertIn("PolicySetterRatifier: runtime=4229 creation=4362", result.stdout)


if __name__ == "__main__":
    unittest.main()