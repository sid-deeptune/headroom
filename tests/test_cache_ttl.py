"""Written cache-TTL contract, exercised through real Swift readers and Pricing.

Run: uv run --with pytest pytest -q tests/test_cache_ttl.py
No application launch, network refresh, source rewriting, or live cache writes.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).parent / "fixtures/cache_ttl"
FIELDS = {"input": "input_tokens", "output": "output_tokens",
          "cache_read": "cache_read_input_tokens", "cache_write": "cache_creation_input_tokens"}
MODEL = "claude-opus-5-5"


@pytest.fixture(scope="session")
def probe(tmp_path_factory):
    executable = tmp_path_factory.mktemp("swift-probe") / "spend-probe"
    sources = [ROOT / "Sources/Headroom" / f"{name}.swift" for name in
               ("Model", "Spend", "Pricing", "ClaudeLogReader", "PiReader", "ClaudeProvider", "Credentials")]
    subprocess.run(["swiftc", "-swift-version", "5", "-enable-bare-slash-regex", *map(str, sources),
                    str(ROOT / "tests/support/SpendProbe.swift"), "-o", str(executable)],
                   check=True, capture_output=True, text=True)
    return executable


@pytest.fixture
def box(tmp_path, probe):
    home = tmp_path / "home"
    price_file = home / "Library/Application Support/Headroom/prices.json"
    price_file.parent.mkdir(parents=True)
    shutil.copyfile(FIXTURES / "prices.json", price_file)
    table = json.loads(price_file.read_text())
    claude = home / ".claude/projects/fixture"
    pi = home / ".pi/agent/sessions/fixture"
    claude.mkdir(parents=True)
    pi.mkdir(parents=True)

    def read(records, harness="claude"):
        path = (claude if harness == "claude" else pi) / "session.jsonl"
        path.write_text("".join(json.dumps(e) + "\n" for e in records))
        before = price_file.read_bytes(), price_file.stat().st_mtime_ns
        env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
        result = subprocess.run([str(probe), harness, str(home / ".claude")],
                                env=env, check=True, capture_output=True, text=True)
        actual = json.loads(result.stdout)
        assert not actual["failed"]
        assert (price_file.read_bytes(), price_file.stat().st_mtime_ns) == before
        return actual["models"]

    return read, table, price_file


def formula(counts, price, one_hour=0):
    return (counts["input"] * price["input"] + counts["output"] * price["output"]
            + counts["cache_read"] * price.get("cache_read", price["input"])
            + (counts["cache_write"] - one_hour) * price.get("cache_write", price["input"])
            + one_hour * 2 * price["input"]) / 1_000_000


def assistant(index, one_hour=0, five_minute=40, split=True):
    usage = dict(input_tokens=7, output_tokens=11, cache_read_input_tokens=13,
                 cache_creation_input_tokens=one_hour + five_minute)
    if split:
        usage["cache_creation"] = {"ephemeral_1h_input_tokens": one_hour,
                                   "ephemeral_5m_input_tokens": five_minute}
    return {"type": "assistant", "timestamp": f"2026-10-{8 + index:02}T12:00:00Z",
            "requestId": f"r{index}", "message": {"id": f"m{index}", "role": "assistant",
                                                   "model": MODEL, "usage": usage}}


def assert_counts(row, counts):
    assert {k: row[k] for k in FIELDS} == counts
    assert row["total"] == sum(counts.values()), "TTL metadata must not double-count cache writes"
    assert not row["incomplete"]


def test_headroom_prices_recorded_transcript_matches_claude_09182048(box):
    read, table, _ = box
    records = [json.loads(line) for line in
               (FIXTURES / "claude-inbox-decisions-transcript.jsonl").read_text().splitlines()]
    best = {}
    for record in records:
        message = record["message"]
        key = (message["id"], record["requestId"])
        if key not in best or message["usage"]["output_tokens"] > best[key]["output_tokens"]:
            best[key] = message["usage"]
    counts = {k: sum(u[f] for u in best.values()) for k, f in FIELDS.items()}
    one_hour = sum(u["cache_creation"]["ephemeral_1h_input_tokens"] for u in best.values())
    assert counts == {"input": 42, "output": 10492, "cache_read": 1164904, "cache_write": 59402}
    assert one_hour == 59402
    expected = formula(counts, table["anthropic"][MODEL], one_hour)
    assert expected == pytest.approx(0.9182048, abs=1e-12)
    row = read(records)[MODEL]
    assert_counts(row, counts)
    assert row["cost"] == pytest.approx(expected, abs=1e-12)


@pytest.mark.parametrize("one_hour,five_minute", [(10, 30), (40, 0), (0, 40)])
def test_split_cache_writes_use_2x_input_and_table_5m_rate_across_days(box, one_hour, five_minute):
    read, table, price_file = box
    # Deliberately not 1.25x input: 5m must use the table, 1h must use 2x input.
    table["anthropic"][MODEL]["cache_write"] = 9
    price_file.write_text(json.dumps(table))
    records = [assistant(1, one_hour, five_minute), assistant(2, one_hour, five_minute)]
    partial = json.loads(json.dumps(records[0]))
    partial["message"]["usage"]["output_tokens"] = 1
    row = read([partial, *records, records[1]])[MODEL]
    counts = {"input": 14, "output": 22, "cache_read": 26, "cache_write": 80}
    assert_counts(row, counts)
    assert row["cost"] == pytest.approx(formula(counts, table["anthropic"][MODEL], 2 * one_hour), abs=1e-12)


def test_old_claude_without_split_keeps_existing_cache_write_price(box):
    read, table, _ = box
    row = read([assistant(1, split=False)])[MODEL]
    counts = {"input": 7, "output": 11, "cache_read": 13, "cache_write": 40}
    assert_counts(row, counts)
    assert row["cost"] == pytest.approx(formula(counts, table["anthropic"][MODEL]), abs=1e-12)


@pytest.mark.parametrize("provider,model,priced_provider,priced_model", [
    ("openai", "gpt-6.1-sol", "openai", "gpt-6.1-sol"),
    ("openai-codex", "gpt-6.1-sol", "openai", "gpt-6.1-sol"),
    ("kimi-coding", "k3", "moonshotai", "kimi-k3"),
])
def test_pi_codex_kimi_keep_existing_pricing(box, provider, model, priced_provider, priced_model):
    read, table, _ = box
    counts = {"input": 7, "output": 11, "cache_read": 13, "cache_write": 40}
    event = {"type": "message", "message": {"role": "assistant", "provider": provider,
             "model": model, "timestamp": 1791547200000,
             "usage": {"input": 7, "output": 11, "cacheRead": 13, "cacheWrite": 40}}}
    row = read([event], "pi")[priced_model]
    assert_counts(row, counts)
    assert row["cost"] == pytest.approx(formula(counts, table[priced_provider][priced_model]), abs=1e-12)
