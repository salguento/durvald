import sys
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from measure_external_players import parse_network_row, timing, phase_summary, aggregate

class ExternalMeasurementTests(unittest.TestCase):
    def test_network_parser_returns_only_pid_and_counters(self):
        self.assertEqual(parse_network_row('com.apple.WebKit.Networking.123,4096,512,'),(123,(4096,512)))
        self.assertIsNone(parse_network_row(',bytes_in,bytes_out,'))
        self.assertIsNone(parse_network_row('process.123,invalid,512,'))
        self.assertIsNone(parse_network_row('missing'))

    def test_timing_requires_observed_progress_and_does_not_invent_missing_events(self):
        events=[dict(event='ready',time=100),dict(event='play_requested',time=110),dict(event='playing',time=150),dict(event='first_progress',time=450)]
        result=timing(events)
        self.assertEqual(result['play_to_progress_ms'],340)
        self.assertEqual(result['ready_to_play_ms'],50)
        self.assertIsNone(result['resume_to_progress_ms'])
        self.assertIsNone(result['seek_to_observed_ms'])

    def test_cpu_uses_time_weighted_intervals_and_phases_remain_separate(self):
        samples=[dict(phase='playback',interval_seconds=1,cpu_delta_seconds=.1,rss_kib=1024),dict(phase='playback',interval_seconds=3,cpu_delta_seconds=.3,rss_kib=2048),dict(phase='paused',interval_seconds=2,cpu_delta_seconds=.01,rss_kib=512)]
        result=phase_summary(samples)
        self.assertAlmostEqual(result['playback']['cpu_mean_percent'],10)
        self.assertEqual(result['playback']['rss_max_mib'],2)
        self.assertAlmostEqual(result['paused']['cpu_mean_percent'],.5)

    def test_limited_or_missing_runs_do_not_become_measured(self):
        summary=aggregate([])
        self.assertEqual(summary['soundcloud']['status'],'limited')
        result=dict(provider='soundcloud',status='limited',network=dict(received_bytes=None,sent_bytes=None),timing={})
        summary=aggregate([result])
        self.assertEqual(summary['soundcloud']['measured_runs'],0)
        self.assertEqual(summary['soundcloud']['received_bytes'],[None])
        self.assertIsNone(summary['soundcloud']['timing_ranges']['play_to_progress_ms']['max'])
