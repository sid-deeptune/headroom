"""Old four-counter panel snapshots retain saved costs, including pre-priceUnavailable records."""
import json
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def snapshot_probe(tmp_path_factory):
    executable = tmp_path_factory.mktemp("snapshot-probe") / "snapshot-probe"
    sources = [ROOT / "Sources/Headroom" / f"{name}.swift" for name in
               ("Model", "Spend", "Pricing", "ClaudeLogReader", "PiReader", "ClaudeProvider", "Credentials", "PanelSnapshot")]
    subprocess.run(["swiftc", "-swift-version", "5", "-enable-bare-slash-regex", *map(str, sources),
                    str(ROOT / "tests/support/SnapshotProbe.swift"), "-o", str(executable)],
                   check=True, capture_output=True, text=True)
    return executable


@pytest.mark.parametrize("with_availability", [False, True])
def test_old_panel_snapshot_decodes_and_round_trips_saved_cost(snapshot_probe, tmp_path, with_availability):
    spend = {"counts": {"input": 7, "output": 11, "cacheRead": 13, "cacheWrite": 40}, "wouldCost": 0.9182048}
    if with_availability:
        spend["priceUnavailable"] = False
    # Swift's non-String-keyed dictionaries encode as alternating key/value arrays.
    snapshot = {"states": [], "spend": ["Claude Deeptune", spend], "staleSpend": [],
                "models": ["Claude Code", {"claude-opus-5-5": spend}], "staleModels": []}
    path = tmp_path / "old-panel.json"
    path.write_text(json.dumps(snapshot))
    before = path.read_bytes(), path.stat().st_mtime_ns
    result = subprocess.run([str(snapshot_probe), str(path)], check=True, capture_output=True, text=True)
    assert json.loads(result.stdout) == {"total": 71, "one_hour": 0, "cost": 0.9182048,
                                       "incomplete": False, "model_cost": 0.9182048,
                                       "round_trip_cost": 0.9182048}
    assert (path.read_bytes(), path.stat().st_mtime_ns) == before
