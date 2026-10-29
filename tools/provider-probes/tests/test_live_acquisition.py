import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from live_acquisition import selection, collect

class LiveAcquisitionTests(unittest.TestCase):
    def selected(self):return dict(query='chosen query',peer='chosen peer',filename='folder\\chosen.flac',size_bytes=4096)
    def test_requires_exact_selection_and_rejects_traversal_unknown_sizes_and_extra_keys(self):
        self.assertEqual(selection(self.selected()),self.selected())
        for change in [dict(peer=''),dict(filename='..\\escape.flac'),dict(size_bytes=True),dict(size_bytes=0),dict(size_bytes=257*1024*1024),dict(filename='other.exe'),dict(query='all',extra='ignored')]:
            with self.subTest(change=change),self.assertRaises(ValueError):selection({**self.selected(),**change})
    def test_phases_are_separate_processes_and_require_cleanup_receipt(self):
        calls=[]
        with tempfile.TemporaryDirectory() as d:
            workspace=Path(d)
            def run(args,**kwargs):
                calls.append(args[-1]);(workspace/f'{args[-1]}-result.json').write_text(json.dumps(dict(status='passed',credential_cleanup_confirmed=True)))
                return type('Result',(),dict(returncode=0,stdout=b'',stderr=b''))()
            with patch('live_acquisition.subprocess.run',side_effect=run):result=collect(Path('/probe'),Path('/config'),{},workspace,100)
            self.assertEqual(calls,['transfer','import','verify']);self.assertEqual(len(result),3)
            self.assertEqual(os.stat(workspace/'transfer.log').st_mode&0o777,0o600)
    def test_failed_or_missing_receipt_never_continues_to_import(self):
        with tempfile.TemporaryDirectory() as d:
            workspace=Path(d)
            with patch('live_acquisition.subprocess.run',return_value=type('Result',(),dict(returncode=1,stdout=b'',stderr=b'private path'))()) as run:
                result=collect(Path('/probe'),Path('/config'),{},workspace,100)
            self.assertEqual(run.call_count,2);self.assertEqual(result['transfer']['status'],'missing_report');self.assertEqual(result['cleanup']['status'],'failed')
