import contextlib
import http.server
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from contracts import Client, ProbeError, accessible_file, search, slskd_client, transfer
from fixture_backend import backend
from probe import bandcamp_probe, fixture_probe, guarded, slskd_probe, soundcloud_api


class ContractsTests(unittest.TestCase):
    def test_incremental_search_cancels_and_removes_only_its_own_id(self):
        with tempfile.TemporaryDirectory() as root, backend(root) as (url,state):
            result=search(slskd_client(url,state.key),"example",polls=3,interval=0)
            self.assertEqual(result["response_counts"],[0,1,2])
            self.assertTrue(all(result["checks"].values()))
            self.assertTrue(state.cancelled and state.deleted)
            self.assertEqual([p for m,p in state.requests if m=="DELETE"],["/api/v0/searches/"+state.search_id])

    def test_auth_failure_never_exposes_key_or_response_body(self):
        with tempfile.TemporaryDirectory() as root, backend(root) as (url,state):
            value=guarded("slskd","live_backend",lambda:slskd_probe(url,"SECRET-TOKEN","example"))
            self.assertEqual(value["reason"],"http_401")
            serialized=json.dumps(value)
            self.assertNotIn("SECRET-TOKEN",serialized)
            self.assertNotIn("do-not-persist",serialized)

    def test_rate_limit_records_retry_without_retry_loop(self):
        with tempfile.TemporaryDirectory() as root, backend(root) as (url,state):
            state.error=429
            value=guarded("slskd","live_backend",lambda:slskd_probe(url,state.key,"example"))
            self.assertEqual(value["retry_after_seconds"],12)
            self.assertEqual(len(state.requests),1)

    def test_search_cleanup_runs_after_polling_error(self):
        with tempfile.TemporaryDirectory() as root, backend(root) as (url,state):
            client=slskd_client(url,state.key); original=client.request
            def request(method,path,*args,**kwargs):
                if path.endswith("/responses"): raise ProbeError("connection_failed")
                return original(method,path,*args,**kwargs)
            client.request=request
            with self.assertRaises(ProbeError): search(client,"example",interval=0)
            self.assertTrue(state.cancelled and state.deleted)

    def test_simulated_success_is_not_a_live_backend_validation(self):
        value=fixture_probe()
        self.assertEqual(value["mode"],"contract_fixture")
        self.assertFalse(value["full_backend_validation"])
        self.assertFalse(value["production_enabled"])
        self.assertTrue(value["transfer"]["completed"])
        self.assertTrue(value["file_mapping"]["accessible"])

    def test_pending_transfer_cancels_only_receipt_identity(self):
        with tempfile.TemporaryDirectory() as root, backend(root) as (url,state):
            state.complete=False
            value=transfer(slskd_client(url,state.key),"fixture-peer","peer\\fixture.wav",64,polls=1,interval=0)
            self.assertFalse(value["completed"]);self.assertTrue(value["cancelled"])
            self.assertEqual([p for m,p in state.requests if m=="DELETE"],["/api/v0/transfers/downloads/fixture-peer/"+state.transfer_id])

    def test_existing_transfer_is_not_reused_or_cancelled(self):
        class Existing:
            def __init__(self):self.calls=[]
            def request(self,method,path,*args,**kwargs):
                self.calls.append(method)
                return [{"filename":"existing.wav","size":64}]
        client=Existing()
        with self.assertRaisesRegex(ProbeError,"existing_transfer"):transfer(client,"user","existing.wav",64)
        self.assertEqual(client.calls,["GET"])

    def test_cancel_failure_preserves_recovery_identity_without_peer_or_key(self):
        with tempfile.TemporaryDirectory() as root, backend(root) as (url,state):
            state.complete=False;client=slskd_client(url,state.key);original=client.request
            def request(method,path,*a,**kw):
                if method=="DELETE":raise ProbeError("http_500")
                return original(method,path,*a,**kw)
            client.request=request
            value=guarded("slskd","live_transfer",lambda:transfer(client,"fixture-peer","peer\\fixture.wav",64,polls=1,interval=0))
            self.assertTrue(value["cleanup"]["operation_may_remain_active"])
            self.assertEqual(value["cleanup"]["transfer_id"],state.transfer_id)
            self.assertNotIn("fixture-peer",json.dumps(value))

    def test_remote_path_is_not_implicitly_a_local_path(self):
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/"file.wav";path.write_bytes(b"abcd")
            value=accessible_file("/remote/downloads/file.wav","/remote/downloads",root,4)
            self.assertTrue(value["accessible"])
            with self.assertRaises(ProbeError):accessible_file("/remote/downloads/file.wav","/wrong",root,4)
            with self.assertRaises(ProbeError):accessible_file("/remote/downloads/file.wav","/remote/downloads",root,5)
            with self.assertRaises(ProbeError):accessible_file("/remote/downloads/file.wav","/remote/downloads",None,4)

    def test_traversal_symlink_and_nonfiles_are_rejected(self):
        with tempfile.TemporaryDirectory() as root,tempfile.TemporaryDirectory() as outside:
            (Path(outside)/"secret").write_bytes(b"abcd")
            (Path(root)/"escape").symlink_to(Path(outside)/"secret")
            for remote in ["/remote/../secret","/remote/escape","/remote/.","C:\\downloads\\file"]:
                with self.subTest(remote=remote),self.assertRaises(ProbeError):accessible_file(remote,"/remote",root,4)

    def test_missing_credentials_do_not_call_network(self):
        with patch("urllib.request.OpenerDirector.open",side_effect=AssertionError("network")):
            self.assertEqual(guarded("slskd","live_backend",lambda:slskd_probe(None,None,"x"))["status"],"blocked")
            self.assertEqual(guarded("soundcloud","live_oauth_api",lambda:soundcloud_api(None,"293"))["status"],"blocked")

    def test_bandcamp_requires_individual_public_track(self):
        for url in ["https://example.org/track/x","https://artist.bandcamp.com/album/x","https://user:token@artist.bandcamp.com/track/x","https://artist.bandcamp.com/track/x?token=secret"]:
            with self.subTest(url=url),self.assertRaises(ProbeError):bandcamp_probe(url)

    def test_credentials_are_not_forwarded_through_redirects(self):
        hits=[]
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                hits.append(self.path)
                self.send_response(302);self.send_header("Location","/target");self.end_headers()
            def log_message(self,*args):pass
        server=http.server.ThreadingHTTPServer(("127.0.0.1",0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            client=Client(f"http://127.0.0.1:{server.server_port}",{"X-API-Key":"secret"})
            with self.assertRaisesRegex(ProbeError,"redirect_blocked"):client.request("GET","start")
            self.assertEqual(hits,["/start"])
        finally:server.shutdown();server.server_close();thread.join()

class EvidenceTests(unittest.TestCase):
    def test_real_bandcamp_metadata_attribute_is_decoded_without_promoting_playback(self):
        import html
        from unittest.mock import MagicMock
        data={"trackinfo":[{"title":"One","duration":90}]}
        body=('<meta property="twitter:player" content="https://bandcamp.com/EmbeddedPlayer/track=123/">'
              '<div data-tralbum="'+html.escape(json.dumps(data),quote=True)+'"></div>').encode()
        response=MagicMock();response.__enter__.return_value=response;response.status=200;response.read.return_value=body
        with patch("urllib.request.OpenerDirector.open",return_value=response):
            value=bandcamp_probe("https://artist.bandcamp.com/track/one")
        self.assertEqual(value["status"],"limited")
        self.assertTrue(value["checks"]["official_embed"])
        self.assertEqual(value["native_audio"],"not_validated")

    def test_signed_stream_urls_are_not_persisted_or_misreported_as_playback(self):
        with patch.object(Client,"request",side_effect=[{"access":"preview"},{"hls_aac_160_url":"https://cdn.example/audio?secret=TOKEN"}]):
            value=soundcloud_api("private-key","293")
        self.assertEqual(value["access"],"preview")
        self.assertFalse(value["media_playback_verified"])
        self.assertNotIn("TOKEN",json.dumps(value));self.assertNotIn("private-key",json.dumps(value))

    def test_pilot_requires_live_controls_end_unavailability_and_matching_sources(self):
        from matrix import build, SOURCES
        from probe import report, write_report
        base=Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            playback=report("youtube","live_official_embed")
            playback.update(status="passed",test_case="playback",observation={"checks":{k:True for k in ("ready","play","progress","pause","resume","seek","ended")}})
            unavailable=report("youtube","live_official_embed")
            unavailable.update(status="passed",test_case="unavailable",observation={"checks":{"unavailable":True}})
            write_report(Path(directory)/"youtube-playback.json",playback)
            write_report(Path(directory)/"youtube-unavailable.json",unavailable)
            self.assertEqual(build(directory)["pilot"]["provider"],"youtube")
            self.assertFalse(build(directory)["pilot"]["production_enabled"])
            playback["observation"]["checks"]["ended"]=False
            write_report(Path(directory)/"youtube-playback.json",playback)
            self.assertIsNone(build(directory)["pilot"])
            playback["observation"]["checks"]["ended"]=True
            playback["mode"]="contract_fixture"
            write_report(Path(directory)/"youtube-playback.json",playback)
            self.assertIsNone(build(directory)["pilot"])
            playback["mode"]="live_official_embed";playback["source_sha256"]["player.js"]="stale"
            write_report(Path(directory)/"youtube-playback.json",playback)
            self.assertIsNone(build(directory)["pilot"])

    def test_verified_audio_widget_is_preferred_and_fixture_error_is_not_live_evidence(self):
        from matrix import build, CONTROLS
        from probe import report, write_report
        with tempfile.TemporaryDirectory() as directory:
            positive=report("soundcloud","live_official_embed")
            positive.update(status="passed",test_case="playback",observation={"checks":{k:True for k in CONTROLS}})
            negative=report("soundcloud","live_official_embed")
            negative.update(status="passed",test_case="unavailable",observation={"checks":{"unavailable":True}})
            write_report(Path(directory)/"soundcloud-widget.json",positive)
            write_report(Path(directory)/"soundcloud-unavailable.json",negative)
            value=build(directory)
            self.assertEqual(value["pilot"]["provider"],"soundcloud")
            self.assertFalse(value["pilot"]["native_audio"])
            self.assertFalse(value["pilot"]["production_enabled"])
            negative["mode"]="contract_fixture"
            write_report(Path(directory)/"soundcloud-unavailable.json",negative)
            self.assertIsNone(build(directory)["pilot"])
