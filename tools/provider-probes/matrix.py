#!/usr/bin/env python3
"""Build a conservative capability decision from fresh, reproducible evidence."""
import argparse
import hashlib
import json
from pathlib import Path
from probe import ROOT, write_report

CONTROLS = ("ready", "play", "progress", "pause", "resume", "seek", "ended")
SOURCES = ("probe.py", "contracts.py", "player.js", "player.html", "WebKitProbe.swift", "fixture_backend.py")
FILES = {"youtube": "youtube-playback.json", "soundcloud": "soundcloud-widget.json",
         "bandcamp": "bandcamp-public.json", "slskd": "slskd-live.json"}


def fresh(value):
    return value.get("schema_version") == 1 and value.get("probe_version") == 1 and all(
        value.get("source_sha256", {}).get(name) == hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES)


def live_player(value, expected):
    return (fresh(value) and expected in ("youtube","soundcloud") and value.get("provider") == expected and value.get("mode") == "live_official_embed" and value.get("test_case") == "playback"
            and value.get("status") == "passed"
            and all(value.get("observation", {}).get("checks", {}).get(key) is True for key in CONTROLS))


def build(directory):
    directory = Path(directory)
    entries = {}
    evidence = {}
    for provider, filename in FILES.items():
        path = directory/filename
        value = json.loads(path.read_text()) if path.exists() else {}
        evidence[provider] = value
        entries[provider] = {"evidence": filename, "evidence_current": fresh(value),
                             "observed_status": value.get("status", "missing"), "production_enabled": False,
                             "embedded_playback": "verified" if live_player(value,provider) else "unverified",
                             "native_audio": "unverified", "download_transfer": "unverified"}
    blocked = directory/"soundcloud-api.json"
    api = json.loads(blocked.read_text()) if blocked.exists() else {}
    entries["soundcloud"]["oauth_api_status"] = api.get("status", "missing") if fresh(api) else "stale_or_missing"
    fixture = directory/"slskd-contract-fixture.json"
    simulated = json.loads(fixture.read_text()) if fixture.exists() else {}
    entries["slskd"]["contract_fixture"] = "verified_simulation_only" if fresh(simulated) and simulated.get("mode") == "contract_fixture" and simulated.get("status") == "passed" else "unverified"
    if fresh(evidence["bandcamp"]) and evidence["bandcamp"].get("checks", {}).get("official_embed") is True:
        entries["bandcamp"]["public_embed_discovery"] = "verified"
    negative = directory/"youtube-unavailable.json"
    unavailable = json.loads(negative.read_text()) if negative.exists() else {}
    negative_ok = (fresh(unavailable) and unavailable.get("provider") == "youtube"
                   and unavailable.get("mode") == "live_official_embed" and unavailable.get("test_case") == "unavailable"
                   and unavailable.get("status") == "passed" and unavailable.get("observation", {}).get("checks", {}).get("unavailable") is True)
    sc_negative = directory/"soundcloud-unavailable.json"
    sc_unavailable = json.loads(sc_negative.read_text()) if sc_negative.exists() else {}
    sc_negative_ok = (fresh(sc_unavailable) and sc_unavailable.get("provider") == "soundcloud"
                      and sc_unavailable.get("mode") == "live_official_embed" and sc_unavailable.get("test_case") == "unavailable"
                      and sc_unavailable.get("status") == "passed" and sc_unavailable.get("observation",{}).get("checks",{}).get("unavailable") is True)
    # Prefer the observed audio-widget path when its positive and negative probes pass.
    # Pilot is a next implementation path, never production enablement or native-audio proof.
    pilot = None
    if live_player(evidence["soundcloud"],"soundcloud") and sc_negative_ok:
        pilot = {"provider":"soundcloud","transport":"official_visible_widget_in_webkit","scope":"individual_audio_track",
                 "production_enabled":False,"native_audio":False,"direct_download":False,"full_vs_preview":"not_verified",
                 "pending":["app_transport_integration","signed_sandbox_build","notarized_distribution","per_item_access"]}
    elif live_player(evidence["youtube"],"youtube") and negative_ok:
        pilot = {"provider":"youtube","transport":"official_visible_iframe_in_webkit","scope":"individual_video",
                 "production_enabled":False,"audio_only":False,"direct_download":False,
                 "pending":["app_transport_integration","signed_sandbox_build","notarized_distribution","per_item_availability"]}
    return {"schema_version":1,"decision_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),"providers":entries,"pilot":pilot,"stage5_conclusion":"pilot_selected" if pilot else "no_pilot_validated",
            "rule":"Simulation, metadata discovery and missing credentials never prove live playback or transfer"}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir",required=True);parser.add_argument("--report",required=True)
    args=parser.parse_args();value=build(args.evidence_dir);write_report(args.report,value)
    print(value["stage5_conclusion"])


if __name__=="__main__":main()
