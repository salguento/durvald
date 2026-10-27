"""Pinned protocol proofs. No UI or music-library dependencies."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

MAX_BODY = 2 * 1024 * 1024


class ProbeError(Exception):
    def __init__(self, kind, retry_after=None, details=None):
        super().__init__(kind)
        self.kind, self.retry_after = kind, retry_after
        self.details = details or {}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, base, headers=None, timeout=5):
        parsed = urllib.parse.urlsplit(base)
        if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ProbeError("invalid_backend_url")
        self.base = base.rstrip("/") + "/"
        self.headers = headers or {}
        self.timeout = timeout
        # Explicitly configured backends should not be routed through an ambient proxy with credentials.
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, method, path, payload=None, accepted=(200, 201, 204)):
        if path.startswith(("/", "//")) or ":" in path or ".." in path.split("/"):
            raise ProbeError("invalid_relative_endpoint")
        url = self.base + path
        data = None if payload is None else json.dumps(payload).encode()
        headers = {"User-Agent": "DurvaldProviderProbe/1", "Accept": "application/json", **self.headers}
        if data is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            response = self.opener.open(req, timeout=self.timeout)
        except urllib.error.HTTPError as error:
            if error.code in accepted:
                error.close()
                return None
            retry = error.headers.get("Retry-After", "")
            error.close()
            raise ProbeError("redirect_blocked" if 300 <= error.code < 400 else f"http_{error.code}",
                             min(int(retry), 3600) if retry.isdigit() else None) from None
        except (OSError, urllib.error.URLError, TimeoutError):
            raise ProbeError("connection_failed") from None
        with response:
            if response.status not in accepted:
                raise ProbeError("unexpected_status")
            body = response.read(MAX_BODY + 1)
        if len(body) > MAX_BODY:
            raise ProbeError("response_too_large")
        if not body:
            return None
        try:
            return json.loads(body)
        except (ValueError, UnicodeError):
            raise ProbeError("invalid_json") from None


def slskd_client(base, key):
    if not base or not key:
        raise ProbeError("backend_not_configured")
    prefix = base.rstrip("/")
    if not prefix.endswith("/api/v0"):
        prefix += "/api/v0"
    return Client(prefix, {"X-API-Key": key})


def search(client, query, polls=4, interval=.5):
    if not query.strip() or len(query) > 200 or not 2 <= polls <= 20 or not 0 <= interval <= 5:
        raise ProbeError("invalid_search_parameters")
    search_id = str(uuid.uuid4())
    checks = {"created": False, "incremental": False, "cancelled": False, "removed_own_search": False}
    counts = []
    created = False
    try:
        value = client.request("POST", "searches", {"id": search_id, "searchText": query, "searchTimeout": 10000})
        if not isinstance(value, dict) or str(value.get("id", "")).lower() != search_id:
            raise ProbeError("invalid_search_identity")
        created = checks["created"] = True
        for index in range(polls):
            if index:
                time.sleep(interval)
            responses = client.request("GET", f"searches/{search_id}/responses")
            if not isinstance(responses, list):
                raise ProbeError("invalid_search_responses")
            counts.append(len(responses))
        checks["incremental"] = any(b > a for a, b in zip(counts, counts[1:]))
    finally:
        if created:
            try:
                client.request("PUT", f"searches/{search_id}", accepted=(200, 304))
                checks["cancelled"] = True
            finally:
                client.request("DELETE", f"searches/{search_id}", accepted=(200, 204))
                checks["removed_own_search"] = True
    return {"checks": checks, "response_counts": counts, "identities_redacted": True}


def accessible_file(remote_path, remote_root, local_root, expected_size):
    """A backend path is never assumed to be an accessible local file."""
    if not isinstance(expected_size, int) or isinstance(expected_size, bool) or expected_size <= 0:
        raise ProbeError("invalid_file_size")
    if not remote_root or not local_root or not remote_path:
        raise ProbeError("file_mapping_required")
    for value in (remote_path, remote_root):
        if "\\" in value or "\x00" in value or ".." in value.split("/"):
            raise ProbeError("unsupported_or_unsafe_remote_path")
    remote, root = PurePosixPath(remote_path), PurePosixPath(remote_root)
    if not remote.is_absolute() or not root.is_absolute():
        raise ProbeError("absolute_remote_path_required")
    try:
        relative = remote.relative_to(root)
        local = Path(local_root).resolve(strict=True)
        candidate = (local / str(relative)).resolve(strict=True)
        candidate.relative_to(local)
        if not candidate.is_file() or candidate.stat().st_size != expected_size:
            raise ProbeError("file_missing_or_incomplete")
        digest = hashlib.sha256()
        with candidate.open("rb") as stream:
            while block := stream.read(65536):
                digest.update(block)
        return {"accessible": True, "bytes": expected_size, "sha256": digest.hexdigest(), "paths_redacted": True}
    except (OSError, ValueError):
        raise ProbeError("file_missing_or_outside_mapping") from None


def transfer(client, username, filename, size, *, polls=6, interval=.5):
    """Explicit transfer only. Ownership comes from the unique batch receipt, never from a title."""
    if not username or not filename or size <= 0 or ".." in filename.replace("\\", "/").split("/") or not 1 <= polls <= 20 or not 0 <= interval <= 5:
        raise ProbeError("invalid_transfer")
    encoded_user = urllib.parse.quote(username, safe="")
    before = client.request("GET", f"transfers/downloads/{encoded_user}")
    if not isinstance(before, list):
        raise ProbeError("invalid_transfer_response")
    if any(r.get("filename") == filename and r.get("size") == size for r in before):
        raise ProbeError("existing_transfer_would_be_reused")
    batch = str(uuid.uuid4())
    result = client.request("POST", "transfers/downloads/batches", {"id": batch, "username": username,
                            "files": [{"filename": filename, "size": size}]}, accepted=(200, 201, 207))
    receipt = result.get("batch") if isinstance(result, dict) else None
    if not isinstance(receipt, dict) or receipt.get("id") != batch:
        raise ProbeError("invalid_batch_identity")
    ids = [r.get("id") for r in (receipt.get("transfers") or [])]
    if len(ids) != 1 or not re_uuid(ids[0]):
        raise ProbeError("transfer_identity_not_observed")
    own_id = ids[0]
    complete = False
    cancelled = False
    try:
        for index in range(polls):
            if index:
                time.sleep(interval)
            row = client.request("GET", f"transfers/downloads/{encoded_user}/{own_id}")
            if not isinstance(row, dict) or row.get("id") != own_id or row.get("batchId") != batch:
                raise ProbeError("mismatched_transfer")
            states = {v.strip() for v in str(row.get("state", "")).split(",")}
            if {"Completed", "Succeeded"}.issubset(states) and row.get("bytesTransferred") == size:
                complete = True
                break
    finally:
        if not complete:
            try:
                client.request("DELETE", f"transfers/downloads/{encoded_user}/{own_id}", accepted=(200, 204))
                cancelled = True
            except ProbeError:
                raise ProbeError("cleanup_failed", details={"operation_may_remain_active":True,"batch_id":batch,"transfer_id":own_id}) from None
    # Transfer API exposes the peer filename, not a resolved destination on this machine.
    return {"completed": complete, "cancelled": cancelled, "bytes": size,
            "destination_mapping_required": True}


def re_uuid(value):
    try:
        return str(uuid.UUID(str(value))) == value
    except (ValueError, AttributeError):
        return False


def soundcloud_api(token, track_id):
    if not token:
        raise ProbeError("oauth_not_configured")
    if not str(track_id).isdigit():
        raise ProbeError("invalid_track_id")
    client = Client("https://api.soundcloud.com", {"Authorization": "OAuth " + token})
    track = client.request("GET", "tracks/" + str(track_id))
    if not isinstance(track, dict) or track.get("access") not in ("playable", "preview", "blocked"):
        raise ProbeError("invalid_track_access")
    access = track["access"]
    result = {"access": access, "media_playback_verified": False, "signed_urls_persisted": False}
    if access != "blocked":
        streams = client.request("GET", f"tracks/{track_id}/streams")
        if not isinstance(streams, dict):
            raise ProbeError("invalid_streams")
        result["format_fields"] = sorted(key for key, value in streams.items() if isinstance(value, str) and value.startswith("https://"))
    return result
