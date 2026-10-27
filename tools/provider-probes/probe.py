#!/usr/bin/env python3
"""Isolated provider feasibility probes. Python standard library; never opens Durvald data."""
import argparse
import datetime as dt
import hashlib
import html
from html.parser import HTMLParser
from contracts import Client, ProbeError, accessible_file, search, slskd_client, soundcloud_api, transfer
import http.server
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent
VERSION = 1


def report(provider, mode):
    return {"schema_version": 1, "probe_version": VERSION, "provider": provider,
            "captured_at": dt.datetime.now(dt.timezone.utc).isoformat(), "mode": mode,
            "status": "inconclusive", "production_enabled": False,
            "host": {"system": platform.system(), "release": platform.release(), "python": platform.python_version()},
            "source_sha256": {name: hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in ("probe.py","contracts.py","player.js","player.html","WebKitProbe.swift","fixture_backend.py")}}


def write_report(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, ensure_ascii=False)
        stream.write("\n")
        temporary = stream.name
    os.replace(temporary, path)


class StaticHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = urllib.parse.urlsplit(self.path).path
        if name not in ("/player.html", "/player.js"):
            self.send_error(404)
            return
        data = (ROOT / name[1:]).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8" if name.endswith("html") else "text/javascript")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def browser_probe(provider, item, case="playback", timeout=65):
    value = report(provider, "live_official_embed")
    value.update(sdk_url="https://www.youtube.com/iframe_api" if provider=="youtube" else "https://w.soundcloud.com/player/api.js",
                 sdk_version="unversioned_remote_api", test_case=case, public_item_id=item, native_audio="not_validated",
                 direct_download="not_validated", signed_url_expiry="not_exposed_by_embed",
                 full_vs_preview="not_verified", distribution="development_only_not_notarized")
    expression = r"[A-Za-z0-9_-]{11}" if provider == "youtube" else r"[0-9]{1,20}"
    if provider not in ("youtube", "soundcloud") or not re.fullmatch(expression, item):
        raise ValueError("Invalid provider or individual item ID")
    if platform.system() != "Darwin":
        value.update(status="blocked", reason="macos_webkit_required")
        return value
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), StaticHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="durvald-probe-") as directory:
            output = Path(directory) / "webkit.json"
            query = urllib.parse.urlencode({"provider": provider, "item": item, "case": case})
            url = f"http://127.0.0.1:{server.server_port}/player.html?{query}"
            module_cache = Path(tempfile.gettempdir()) / "durvald-provider-probe-swift-cache"
            module_cache.mkdir(exist_ok=True)
            command = ["/usr/bin/swift", "-module-cache-path", str(module_cache), str(ROOT / "WebKitProbe.swift"),
                       "--url", url, "--report", str(output), "--timeout", str(timeout)]
            try:
                result = subprocess.run(command, capture_output=True, timeout=timeout + 90, check=False)
                if output.is_file():
                    value["observation"] = json.loads(output.read_text())
                    value["status"] = value["observation"]["status"]
                    if result.returncode:
                        value.update(status="failed", reason="webkit_process_failed")
                else:
                    value.update(status="blocked", reason="webkit_report_missing", process_exit=result.returncode)
                    # Compiler/runtime logs stay outside the durable report, never inline secrets or URLs.
                    print(result.stderr.decode(errors="replace")[-3000:])
            except subprocess.TimeoutExpired:
                value.update(status="inconclusive", reason="webkit_process_timeout")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
    return value


class BandcampPage(HTMLParser):
    def __init__(self):
        super().__init__(); self.embed = None; self.tralbum = None; self.title = None
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "meta" and (attrs.get("name") or attrs.get("property")) == "twitter:player": self.embed = attrs.get("content")
        if tag == "meta" and attrs.get("property") == "og:title": self.title = attrs.get("content")
        if "data-tralbum" in attrs:
            try: self.tralbum = json.loads(attrs["data-tralbum"])
            except ValueError: pass


def bandcamp_probe(url):
    value = report("bandcamp", "live_public_page")
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or not parsed.hostname.endswith(".bandcamp.com") or parsed.username or parsed.password or parsed.port or parsed.query or parsed.fragment or not re.fullmatch(r"/track/[^/]+", parsed.path):
        raise ProbeError("individual_public_bandcamp_track_required")
    client = Client(f"https://{parsed.hostname}")
    request = urllib.request.Request(url, headers={"User-Agent": "DurvaldProviderProbe/1"})
    try:
        with client.opener.open(request, timeout=10) as response:
            body = response.read(2*1024*1024 + 1)
            status = response.status
    except (OSError, urllib.error.URLError):
        raise ProbeError("bandcamp_page_unavailable") from None
    if len(body) > 2*1024*1024: raise ProbeError("response_too_large")
    page = BandcampPage(); page.feed(body.decode("utf-8"))
    embed = urllib.parse.urlsplit(page.embed or "")
    valid = embed.scheme == "https" and embed.hostname == "bandcamp.com" and embed.path.startswith("/EmbeddedPlayer/")
    tracks = (page.tralbum or {}).get("trackinfo") or []
    single = len(tracks) == 1
    value.update(status="limited" if valid and single else "inconclusive", public_url=url,
                 checks={"public_page":status == 200,"official_embed":valid,"individual_track":single},
                 page_sha256=hashlib.sha256(body).hexdigest(), full_vs_preview="not_verified",
                 native_audio="not_validated", player_control_events="not_validated",
                 download="open_purchase_or_service_only")
    return value


def slskd_probe(base, key, query, *, mode="live_backend", polls=4, interval=.5):
    value = report("slskd", mode)
    client = slskd_client(base, key)
    version = client.request("GET", "application/version")
    if isinstance(version, str) and re.fullmatch(r"[A-Za-z0-9.+_-]{1,80}", version):
        value["backend_version"] = version
    elif isinstance(version, dict):
        value["backend_version"] = {k:v for k,v in version.items() if k in ("major","minor","patch") and type(v) is int}
    else:
        raise ProbeError("invalid_backend_version")
    state = client.request("GET", "server")
    value["server_connected"] = state.get("isConnected") is True if isinstance(state,dict) else False
    if not value["server_connected"]: raise ProbeError("soulseek_not_connected")
    value["search"] = search(client, query, polls=polls, interval=interval)
    value["status"] = "passed" if all(value["search"]["checks"].values()) else "limited"
    value["download"] = "not_requested"
    value["reference_contract"] = "slskd/0.26.2"
    value["full_backend_validation"] = mode == "live_backend"
    return value


def fixture_probe():
    from fixture_backend import backend
    with tempfile.TemporaryDirectory(prefix="durvald-slskd-fixture-") as root:
        with backend(root) as (url,state):
            value = slskd_probe(url,state.key,"fixture query",mode="contract_fixture",polls=3,interval=0)
            value["transfer"] = transfer(slskd_client(url,state.key),"fixture-peer","peer\\fixture.wav",64,polls=2,interval=0)
            value["file_mapping"] = accessible_file("/remote/downloads/fixture.wav","/remote/downloads",root,64)
            value["full_backend_validation"] = False
            value["fixture_note"] = "Local HTTP simulator; not a Soulseek network or real backend proof"
            return value


def live_transfer(args):
    value = report("slskd","live_transfer")
    client = slskd_client(os.environ.get("SLSKD_URL"),os.environ.get("SLSKD_API_KEY"))
    value["transfer"] = transfer(client,args.username,args.filename,args.size,polls=args.polls,interval=args.interval)
    value["status"] = "limited"
    if value["transfer"]["completed"]:
        value["file_mapping"] = accessible_file(args.completed_remote_path,args.remote_root,args.local_root,args.size)
        value["status"] = "passed"
    return value


def guarded(provider, mode, operation):
    try: return operation()
    except (OSError, ValueError):
        value = report(provider,mode)
        value.update(status="blocked",reason="probe_environment_unavailable")
        return value
    except ProbeError as error:
        value = report(provider,mode)
        value.update(status="blocked" if error.kind in ("backend_not_configured","oauth_not_configured","soulseek_not_connected") else "failed", reason=error.kind)
        if error.details: value["cleanup"] = error.details
        if error.retry_after is not None: value["retry_after_seconds"] = error.retry_after
        return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    browser = sub.add_parser("browser")
    browser.add_argument("provider", choices=["youtube", "soundcloud"])
    browser.add_argument("--item", required=True)
    browser.add_argument("--case", choices=["playback", "unavailable"], default="playback")
    browser.add_argument("--report", required=True)
    bandcamp = sub.add_parser("bandcamp")
    bandcamp.add_argument("--url",required=True); bandcamp.add_argument("--report",required=True)
    slskd = sub.add_parser("slskd")
    slskd.add_argument("--query",default="durvald provider proof"); slskd.add_argument("--report",required=True)
    fixture = sub.add_parser("slskd-fixture"); fixture.add_argument("--report",required=True)
    sc = sub.add_parser("soundcloud-api"); sc.add_argument("--track-id",required=True); sc.add_argument("--report",required=True)
    download = sub.add_parser("slskd-transfer", help="Explicit individual download test; never uses arbitrary search results")
    download.add_argument("--username",required=True); download.add_argument("--filename",required=True)
    download.add_argument("--size",type=int,required=True); download.add_argument("--polls",type=int,default=6)
    download.add_argument("--interval",type=float,default=.5)
    download.add_argument("--completed-remote-path",required=True); download.add_argument("--remote-root",required=True)
    download.add_argument("--local-root",required=True); download.add_argument("--report",required=True)
    args = parser.parse_args()
    if args.command == "browser":
        value = guarded(args.provider,"live_official_embed",lambda:browser_probe(args.provider, args.item, args.case))
    elif args.command == "bandcamp":
        value = guarded("bandcamp","live_public_page",lambda:bandcamp_probe(args.url))
    elif args.command == "slskd":
        value = guarded("slskd","live_backend",lambda:slskd_probe(os.environ.get("SLSKD_URL"),os.environ.get("SLSKD_API_KEY"),args.query))
    elif args.command == "slskd-fixture":
        value = guarded("slskd","contract_fixture",fixture_probe)
    elif args.command == "slskd-transfer":
        value = guarded("slskd","live_transfer",lambda:live_transfer(args))
    else:
        def sc_probe():
            value = report("soundcloud","live_oauth_api")
            value.update(status="limited",observation=soundcloud_api(os.environ.get("SOUNDCLOUD_ACCESS_TOKEN"),args.track_id))
            return value
        value = guarded("soundcloud","live_oauth_api",sc_probe)
    write_report(args.report, value)
    print(f"{value['provider']}: {value['status']}")


if __name__ == "__main__":
    main()
