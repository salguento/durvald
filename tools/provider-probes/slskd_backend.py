#!/usr/bin/env python3
"""Isolated native slskd validation backend. Private state is never committed."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import secrets
import signal
import socket
import stat
import subprocess
import tempfile
import time
import urllib.request
import zipfile

from contracts import ProbeError, slskd_client
from probe import ROOT, guarded, slskd_probe, write_report

VERSION = "0.26.2"
ASSET = "slskd-0.26.2-osx-arm64.zip"
SHA256 = "18d3ebf7760cd93296b61f640c87b383b41a142cd445a04a633d3b596313ef85"
STATE = ROOT / ".state" / "slskd"


def private_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        temporary = stream.name
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def checked_members(archive):
    for member in archive.infolist():
        name = PurePosixPath(member.filename)
        mode = member.external_attr >> 16
        if name.is_absolute() or ".." in name.parts or "\\" in member.filename or stat.S_ISLNK(mode):
            raise ValueError("Unsafe release archive")
        if member.file_size > 200 * 1024 * 1024:
            raise ValueError("Oversized archive member")
    if sum(m.file_size for m in archive.infolist()) > 512 * 1024 * 1024:
        raise ValueError("Oversized release archive")


def initialize(state=STATE):
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(state, 0o700)
    credentials = state / "credentials.json"
    if credentials.exists():
        values = json.loads(credentials.read_text())
    else:
        values = {"api_key": secrets.token_urlsafe(40), "web_username": "durvald-validation",
                  "web_password": secrets.token_urlsafe(32), "port": 5030}
        private_json(credentials, values)
    for name in ["data", "downloads", "incomplete"]:
        directory = state/name
        directory.mkdir(exist_ok=True, mode=0o700)
    return values


def configure(state=STATE, new_account=False, server_address=None, server_port=None):
    values = initialize(state)
    if server_address is not None or server_port is not None:
        if server_address is not None:
            if not server_address or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-" for c in server_address):
                raise ValueError("Invalid Soulseek server address")
            values["server_address"] = server_address
        if server_port is not None:
            if not 1 <= server_port <= 65535: raise ValueError("Invalid Soulseek server port")
            values["server_port"] = server_port
        private_json(state/"credentials.json", values)
    if new_account and not values.get("soulseek_username"):
        values["soulseek_username"] = "durvald-probe-" + secrets.token_hex(7)
        values["soulseek_password"] = secrets.token_urlsafe(28)
        private_json(state/"credentials.json", values)
    config = {
        "remote_configuration": False, "remote_file_management": False,
        "web": {"port": values["port"], "ip_address": "127.0.0.1", "logging": False,
                "https": {"disabled": True}, "authentication": {
                    "disabled": False, "username": values["web_username"], "password": values["web_password"],
                    "api_keys": {"durvald_validation": {"key": values["api_key"], "cidr": "127.0.0.1/32", "role": "Administrator"}}}},
        "directories": {"downloads": str((state/"downloads").resolve()), "incomplete": str((state/"incomplete").resolve())},
        "shares": {"directories": []},
        "soulseek": {"address":values.get("server_address","vps.slsknet.org"),"port":values.get("server_port",2271),"username": values.get("soulseek_username", ""), "password": values.get("soulseek_password", ""), "listen_port": 50300},
        "flags": {"no_connect": not bool(values.get("soulseek_username")), "no_share_scan": False, "no_version_check": True},
    }
    # JSON is a valid YAML flow document; quote every value without template injection.
    private_json(state/"slskd.yml", config)
    return values


def verified_installation(state=STATE):
    """Validate the pinned installation without downloads or executing the helper."""
    manifest = json.loads((state/"installation.json").read_text())
    if (manifest.get("version"), manifest.get("asset"), manifest.get("asset_sha256")) != (VERSION, ASSET, SHA256):
        raise ValueError("Incompatible pinned installation")
    relative = PurePosixPath(manifest.get("binary", ""))
    if relative.is_absolute() or ".." in relative.parts or not relative.parts or relative.parts[0] != "release":
        raise ValueError("Invalid installed executable path")
    binary = state/str(relative)
    release = (state/"release").resolve()
    if (state/"release").is_symlink() or not binary.is_file() or not binary.resolve().is_relative_to(release) or binary.is_symlink():
        raise ValueError("Installed executable missing or outside release")
    if hashlib.sha256(binary.read_bytes()).hexdigest() != manifest.get("binary_sha256"):
        raise ValueError("Installed executable checksum mismatch")
    if not os.access(binary, os.X_OK):
        raise ValueError("Installed executable is not executable")
    return binary


def install(state=STATE):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("This pinned installer targets macOS ARM64")
    initialize(state)
    manifest_path = state/"installation.json"
    if manifest_path.exists():
        return verified_installation(state)
    release = json.load(urllib.request.urlopen(f"https://api.github.com/repos/slskd/slskd/releases/tags/{VERSION}", timeout=20))
    asset = next(item for item in release["assets"] if item["name"] == ASSET)
    if asset.get("digest") != "sha256:" + SHA256:
        raise ValueError("Release metadata checksum changed")
    url = f"https://github.com/slskd/slskd/releases/download/{VERSION}/{ASSET}"
    with tempfile.TemporaryDirectory(prefix="slskd-install-", dir=state) as directory:
        package = Path(directory)/ASSET
        digest = hashlib.sha256()
        total = 0
        with urllib.request.urlopen(url, timeout=45) as response, package.open("wb") as stream:
            while block := response.read(1024 * 1024):
                total += len(block)
                if total > 100 * 1024 * 1024:
                    raise ValueError("Oversized release download")
                digest.update(block)
                stream.write(block)
        if digest.hexdigest() != SHA256:
            raise ValueError("Release checksum mismatch")
        extracted = Path(directory)/"unpacked"
        with zipfile.ZipFile(package) as archive:
            checked_members(archive)
            archive.extractall(extracted)
        candidates = list(extracted.rglob("slskd"))
        candidates = [p for p in candidates if p.is_file()]
        if len(candidates) != 1:
            raise ValueError("Ambiguous executable in release")
        relative = candidates[0].relative_to(extracted)
        candidates[0].chmod(0o700)
        target = state/"release"
        if target.exists():
            raise ValueError("Release directory exists without a manifest")
        extracted.rename(target)
    binary = target/relative
    manifest = {"version": VERSION, "asset": ASSET, "asset_sha256": SHA256,
                "binary": str(binary.relative_to(state)), "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                "installed_at": dt.datetime.now(dt.timezone.utc).isoformat(), "source": url}
    private_json(manifest_path, manifest)
    return binary


def client(state=STATE):
    values = json.loads((state/"credentials.json").read_text())
    return slskd_client(f"http://127.0.0.1:{values['port']}", values["api_key"])


def status(state=STATE):
    c = client(state)
    try:
        version = c.request("GET", "application/version")
        server = c.request("GET", "server")
        return {"api_authenticated": True, "version": version, "soulseek_connected": server.get("isConnected") is True,
                "soulseek_logged_in": server.get("isLoggedIn") is True, "url": f"http://127.0.0.1:{json.loads((state/'credentials.json').read_text())['port']}"}
    except ProbeError as error:
        return {"api_authenticated": False, "reason": error.kind}


def owned_pid(state=STATE):
    path = state/"process.json"
    if not path.exists():
        return None
    record = json.loads(path.read_text())
    pid = record.get("pid")
    if not isinstance(pid, int) or pid < 2:
        raise ValueError("Invalid process record")
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
    if not result.stdout.strip():
        return None
    if record["binary"] not in result.stdout or str(state/"data") not in result.stdout:
        raise ValueError("PID no longer belongs to this validation backend")
    return pid


def start(state=STATE):
    values = configure(state)
    existing = owned_pid(state)
    if existing:
        return status(state)
    binary = install(state)
    with socket.socket() as test:
        test.bind(("127.0.0.1", values["port"]))
    environment = {k:v for k,v in os.environ.items() if not k.startswith("SLSKD_")}
    environment.update(DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1",
                       DOTNET_BUNDLE_EXTRACT_BASE_DIR=str(state/"dotnet-bundle"))
    log = state/"backend.log"
    descriptor = os.open(log, os.O_WRONLY|os.O_CREAT|os.O_APPEND, 0o600)
    with os.fdopen(descriptor, "ab") as stream:
        process = subprocess.Popen([str(binary), "--app-dir", str(state/"data"), "--config", str(state/"slskd.yml")],
                                   cwd=binary.parent, env=environment, stdin=subprocess.DEVNULL, stdout=stream, stderr=stream,
                                   start_new_session=True, umask=0o077)
    try:
        private_json(state/"process.json", {"pid": process.pid, "binary": str(binary), "started_at": dt.datetime.now(dt.timezone.utc).isoformat()})
        for _ in range(40):
            if process.poll() is not None:
                raise ValueError("Backend exited; inspect the private backend log locally")
            value = status(state)
            if value["api_authenticated"] and (not values.get("soulseek_username") or value.get("soulseek_logged_in")):
                return value
            time.sleep(.5)
        if value.get("api_authenticated"):
            value["connection_pending"] = True
            return value
        raise ValueError("Backend API did not become ready")
    except BaseException:
        # This exact Popen belongs to this invocation. Failed startup must not
        # leave an untracked daemon; an already-running daemon is never killed.
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
        (state/"process.json").unlink(missing_ok=True)
        raise


def stop(state=STATE):
    pid = owned_pid(state)
    if pid:
        os.kill(pid, signal.SIGTERM)
        for _ in range(40):
            if owned_pid(state) is None:
                break
            time.sleep(.25)
        else:
            raise ValueError("Backend did not stop; no forced termination performed")
    (state/"process.json").unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["install", "verify", "configure", "start", "stop", "status", "probe"])
    parser.add_argument("--new-test-account", action="store_true", help="Creates local credentials; account is established on first network login")
    parser.add_argument("--server-address")
    parser.add_argument("--server-port",type=int)
    parser.add_argument("--report")
    parser.add_argument("--query", default="creative commons")
    args = parser.parse_args()
    try:
        if args.command == "install":
            install(); print("Official slskd package installed and checksum verified")
        elif args.command == "verify":
            verified_installation(); print("Pinned slskd executable verified offline; nothing started")
        elif args.command == "configure":
            configure(new_account=args.new_test_account,server_address=args.server_address,server_port=args.server_port); print("Private local configuration ready; credentials not printed")
        elif args.command == "start":
            print(json.dumps(start(), indent=2))
        elif args.command == "stop":
            stop(); print("Validation backend stopped")
        elif args.command == "status":
            print(json.dumps(status(), indent=2))
        else:
            if not args.report:
                parser.error("--report is required for probe")
            values = initialize()
            value = guarded("slskd", "live_backend", lambda: slskd_probe(f"http://127.0.0.1:{values['port']}", values["api_key"], args.query, polls=8, interval=1))
            value["live_backend_contacted"] = "backend_version" in value
            value["full_backend_validation"] = False
            value["pending"] = ["real_peer_transfer", "file_mapping_after_real_transfer"]
            if not value.get("search",{}).get("checks",{}).get("incremental"):
                value["pending"].append("incremental_search_responses")
            value["backend_setup_script_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
            write_report(args.report, value); print("slskd: " + value["status"])
    except (ValueError, OSError, ProbeError) as error:
        # Intentionally avoid serializing exception text containing paths, config or request values.
        print("Backend operation failed: " + type(error).__name__)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
