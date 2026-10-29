"""CLI preflight checks against the compiled production-facade probe, no HTTP."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
BINARY = REPO / "durvald-core/target/debug/examples/service_collection_probe"
TARGETS = REPO / "tools/provider-probes/fixtures/service-collection-targets.json"


class CollectionPreflightTests(unittest.TestCase):
    def run_probe(self, provider, root, credential=None):
        env = os.environ.copy()
        env.pop("SOUNDCLOUD_ACCESS_TOKEN", None)
        env.pop("YOUTUBE_API_KEY", None)
        if credential:
            env["YOUTUBE_API_KEY"] = credential
        return subprocess.run(
            [str(BINARY), str(TARGETS), provider, "capture", str(root)],
            env=env, capture_output=True, text=True, timeout=15, check=False,
        )

    def test_missing_credentials_block_both_providers_without_creating_library(self):
        with tempfile.TemporaryDirectory() as parent:
            for provider in ("soundcloud", "youtube"):
                root = Path(parent) / provider
                result = self.run_probe(provider, root)
                self.assertEqual(result.returncode, 0, result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual(report["status"], "blocked")
                self.assertFalse(report["network_attempted"])
                self.assertFalse(report["library_opened"])
                self.assertFalse(root.exists())

    def test_existing_library_is_refused_without_exposing_supplied_key(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent)
            sentinel = root / "library.sqlite"
            sentinel.write_bytes(b"personal-library-do-not-touch")
            credential = "test-value-must-never-be-printed"
            result = self.run_probe("youtube", root, credential)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(credential, result.stdout + result.stderr)
            self.assertEqual(sentinel.read_bytes(), b"personal-library-do-not-touch")
            self.assertEqual(list(root.iterdir()), [sentinel])


if __name__ == "__main__":
    unittest.main()
