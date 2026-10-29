import sys
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from measure_integrations import cpu_seconds, summarize

class MeasurementTests(unittest.TestCase):
    def test_cpu_time_conversion_preserves_fractional_seconds(self):
        self.assertAlmostEqual(cpu_seconds('1:02.25'),62.25)
        self.assertEqual(cpu_seconds('1:01:00'),3660)

    def test_missing_and_exceeded_metrics_never_approve_phase(self):
        self.assertEqual(summarize([], 'idle')['status'],'insufficient_samples')
        rows=[dict(phase='idle',cpu_percent=0.1,rss_kib=102400,disk_bytes=0,children=0) for _ in range(6)]
        self.assertEqual(summarize(rows,'idle')['status'],'passed')
        rows[-1]['disk_bytes']=2*1048576
        self.assertEqual(summarize(rows,'idle')['status'],'budget_exceeded')
