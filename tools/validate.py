#!/usr/bin/env python3
"""Offline validation of the manifest, operational templates and compiled launch artifacts."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return json.loads((ROOT / path).read_text())


def main():
    m = read("launch.json")
    assert set(m) == {"kind", "hook", "token", "pool", "notes"}
    assert m["kind"] == "univ4_hook"
    assert isinstance(m["notes"], str) and m["notes"]
    assert m["hook"]["contract"] == "HackathonMachine"
    assert m["hook"]["constructorArgs"] == [
        "$poolManager", "$owner", "$factory", "$token",
        "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "0x5598aa9146215bc13eb26f2c692ad1461fd32982"
    ]
    for value in m["hook"]["constructorArgs"]:
        assert isinstance(value, str)
        assert value in ("$poolManager", "$owner", "$factory", "$token") or re.fullmatch(r"0x[0-9a-f]{40}|[0-9]+", value)
    assert m["hook"]["permissions"] == [
        "beforeInitialize", "beforeSwap", "afterSwap", "beforeSwapReturnDelta", "afterSwapReturnDelta"
    ]
    assert m["token"] == {"contract": "HackToken", "name": "TONOFHACKATHONS", "symbol": "HACK", "decimals": 18}
    assert m["pool"] == {
        "pairedCurrency": "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "fee": 12500,
        "tickSpacing": 60, "initialPrice": "125270724187523965593206900"
    }
    b = read("docs/heartbeat.json")
    assert b["window"] == {"fromBlock": "$deploymentBlock", "toBlock": "$deploymentBlockPlusOne"}
    assert b["consumer"] == {"chainId": 1, "verifyingContract": "$hook"}
    assert b["chainId"] == 1 and b["v"] == 1 and b["answerType"] == "bytes32" and b["evidence"] == "panel"
    assert b["panelSize"] == 7 and b["quorum"] == 5
    assert b["guards"] == {"sources": ["https://github.com/", "https://explorer.imd.fun/", "https://api.imd.fun/"], "minSources": 2}
    assert 1 <= len(b["question"]) <= 2000
    assert len(json.dumps(b).encode()) <= 16384
    assert all(1 <= len(k) <= 64 and 1 <= len(v) <= 512 for k, v in b["definitions"].items())
    assert read("docs/schedule.json")["cadence"] == {"cron": "0 1 * * 1", "tz": "UTC"}
    assert read("docs/launch-request.json")["economics"] == {"poolBps": 9000}
    for contract in ("HackToken", "HackathonMachine"):
        artifact = read(f"out/{contract}.sol/{contract}.json")
        assert not artifact["bytecode"].get("linkReferences")
        code = bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x"))
        assert 0 < len(code) <= 24576
        i = 0
        while i < len(code):
            op = code[i]
            assert op not in (0xF2, 0xF4, 0xFF), f"forbidden opcode in {contract} at {i}"
            i += 1 + (op - 0x5F if 0x60 <= op <= 0x7F else 0)
        print(f"{contract}: {len(code)} runtime bytes; no external library links or forbidden opcodes")
    print("launch.json and heartbeat/schedule templates valid")


if __name__ == "__main__":
    main()
