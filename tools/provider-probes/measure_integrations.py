#!/usr/bin/env python3
"""Release core baseline in a disposable library. No personal data or remote calls."""
import argparse
import datetime as dt
import json
import hashlib
from pathlib import Path
import platform
import selectors
import subprocess
import tempfile
import time
import wave

ROOT = Path(__file__).resolve().parents[2]
BUDGETS = {"idle": {"cpu_mean_percent": 2, "rss_max_mib": 512, "disk_growth_bytes": 1048576},
           "playback": {"cpu_mean_percent": 30, "rss_max_mib": 512, "disk_growth_bytes": 1048576}}


def cpu_seconds(value):
    parts = value.strip().split(":")
    return sum(float(part) * 60 ** i for i, part in enumerate(reversed(parts)))


def process_tree(pid):
    output = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,time=,rss="], capture_output=True, text=True, check=True).stdout
    rows = {}
    for line in output.splitlines():
        values = line.split()
        if len(values) == 4:
            rows[int(values[0])] = (int(values[1]), cpu_seconds(values[2]), int(values[3]))
    selected = {pid}
    while True:
        children = {p for p, row in rows.items() if row[0] in selected}
        updated = selected | children
        if updated == selected:
            break
        selected = updated
    return {p: rows[p] for p in selected if p in rows}


def disk_bytes(directory):
    # Exclude the fixed WAV stimulus; count SQLite/WAL/cache/settings allocation.
    return sum(p.stat().st_blocks * 512 for p in directory.rglob("*") if p.is_file() and p.name != "baseline-fixture.wav")


def summarize(samples, phase, disk_start=None):
    rows = [s for s in samples if s["phase"] == phase]
    if len(rows) < 5:
        return {"status": "insufficient_samples", "samples": len(rows)}
    result = {"samples": len(rows), "cpu_mean_percent": sum(r["cpu_percent"] for r in rows)/len(rows),
              "rss_max_mib": max(r["rss_kib"] for r in rows)/1024,
              "disk_growth_bytes": max(0, max(r["disk_bytes"] for r in rows)-(rows[0]["disk_bytes"] if disk_start is None else disk_start)),
              "children_max": max(r["children"] for r in rows)}
    checks = {key: result[key] <= limit for key, limit in BUDGETS[phase].items()}
    result.update(checks=checks, budgets=BUDGETS[phase], status="passed" if all(checks.values()) else "budget_exceeded")
    return result


def run(binary, broken_plugins=False):
    samples, events, phase_disk = [], [], {}
    with tempfile.TemporaryDirectory(prefix="durvald-integration-baseline-") as temporary:
        directory = Path(temporary)
        with wave.open(str(directory/"baseline-fixture.wav"), "wb") as stream:
            stream.setnchannels(2); stream.setsampwidth(2); stream.setframerate(44100)
            stream.writeframes(bytes(44100*4*60))
        if broken_plugins:
            (directory/"music-plugins.json").write_text('{"version":99,"plugins":{}}')
        with tempfile.TemporaryFile(mode="w+") as errors:
            process = subprocess.Popen([str(binary), str(directory)], stdout=subprocess.PIPE, stderr=errors, text=True)
            selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
            phase = "startup"; previous = None; observed_children = set(); started = time.monotonic()
            try:
                while time.monotonic()-started < 180:
                    for key, _ in selector.select(timeout=0.2):
                        line = key.fileobj.readline()
                        if not line:
                            selector.unregister(key.fileobj)
                        elif line.startswith("DURVALD_BASELINE "):
                            event = json.loads(line.removeprefix("DURVALD_BASELINE ")); events.append(event)
                            phase = event["phase"]; previous = None
                            phase_disk[phase] = disk_bytes(directory)
                    now = time.monotonic()
                    if previous is None or now-previous[0] >= 0.9:
                        tree = process_tree(process.pid)
                        observed_children.update(set(tree)-{process.pid})
                        total = sum(row[1] for row in tree.values())
                        if previous is not None and phase in BUDGETS and process.pid in tree:
                            samples.append({"phase":phase,"elapsed_seconds":now-started,
                                            "cpu_percent":max(0,total-previous[1])/(now-previous[0])*100,
                                            "rss_kib":sum(row[2] for row in tree.values()),
                                            "disk_bytes":disk_bytes(directory),"children":len(tree)-1})
                        previous = (now,total)
                    if process.poll() is not None:
                        break
                else:
                    raise TimeoutError("Baseline exceeded 180 seconds")
                if process.returncode != 0:
                    raise RuntimeError("Native baseline failed; no performance approval")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
                selector.close(); process.stdout.close()
            results = [e for e in events if e["phase"] == "result"]
            if len(results) != 1:
                raise RuntimeError("Missing baseline result")
            survivors = []
            for pid in observed_children:
                alive = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "pid="], capture_output=True, text=True).stdout.strip()
                if alive: survivors.append(pid)
            result = results[0]
            result.update(broken_plugin_preferences=broken_plugins, resource_phases={p:summarize(samples,p,phase_disk.get(p)) for p in BUDGETS}, samples=samples,
                          child_processes_observed=len(observed_children), children_alive_after_exit=len(survivors),
                          network_bytes=None, network_measurement="Not instrumented; no remote operations issued. SDK cost requires a separate real WebKit run.")
            passed = all(m.get("passed",True) for m in result["metrics"]) and all(p["status"]=="passed" for p in result["resource_phases"].values()) and not survivors
            result["status"] = "passed" if passed else "budget_exceeded"
            return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT/"durvald-core/target/release/examples/integration_baseline")
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--broken-plugins", action="store_true", help="Exercise local audio with future/incompatible plugin preferences")
    args = parser.parse_args()
    if args.report.exists(): parser.error("Refusing to replace an existing report")
    try:
        report = run(args.binary.resolve(), args.broken_plugins)
    except (OSError, RuntimeError, TimeoutError, ValueError) as error:
        report = {"status":"blocked", "reason":type(error).__name__, "performance_approved":False}
    report.update(executor_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest() if args.binary.is_file() else None,
                  source_sha256=hashlib.sha256((ROOT/"durvald-core/examples/integration_baseline.rs").read_bytes()).hexdigest(), schema=1, measured_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                  hardware={"architecture":platform.machine(),"os":platform.platform(),
                            "model":subprocess.run(["sysctl","-n","hw.model"],capture_output=True,text=True).stdout.strip()},
                  network="No external requests. User reports workplace network restrictions; remote metrics remain unmeasured.",
                  git_commit=subprocess.run(["git","-C",str(ROOT),"rev-parse","HEAD"],capture_output=True,text=True).stdout.strip(),
                  dirty_tree=bool(subprocess.run(["git","-C",str(ROOT),"status","--porcelain"],capture_output=True,text=True).stdout.strip()))
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(report,indent=2)+"\n")
    print("Integration baseline: " + report["status"])
    return 0 if report["status"]=="passed" else 1

if __name__ == "__main__":
    raise SystemExit(main())
