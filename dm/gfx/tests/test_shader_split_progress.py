"""shader_split.py's progress lines: the jobs are counted as they finish, in any order, while the results keep the job order."""
import concurrent.futures as cf
import contextlib
import io
from pathlib import Path
import sys
import threading
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import shader_split as split


class PooledProgressTests(unittest.TestCase):
    def test_a_slow_first_job_does_not_hold_the_count(self):
        release = threading.Event()
        def scan(job):   # job 0 is a large archive range: it finishes only after the others
            if job == 0: release.wait(5)
            return job
        lines = io.StringIO()
        with mock.patch.object(split, 'scan_file', scan), cf.ThreadPoolExecutor(4) as ex, contextlib.redirect_stdout(lines):
            def watch():   # the count reaches 19 of 20 while job 0 still runs, then job 0 is let go
                while 'progress: 19/20' not in lines.getvalue(): threading.Event().wait(0.05)
                release.set()
            threading.Thread(target=watch, daemon=True).start()
            results = split.pooled(ex, list(range(20)), 20)
        self.assertEqual(results, list(range(20)))   # the job order, as pool.map gave it
        counts = [l for l in lines.getvalue().split('\n') if l.startswith('progress: ')]
        self.assertIn('progress: 19/20', counts)
        self.assertEqual(counts[-1], 'progress: 20/20')

    def test_batches_and_an_offset_count_every_job_once(self):
        lines = io.StringIO()
        with mock.patch.object(split, 'scan_file', lambda job: job * 2), cf.ThreadPoolExecutor(3) as ex, contextlib.redirect_stdout(lines):
            results = split.pooled(ex, list(range(37)), 40, start=3, chunk=16)
        self.assertEqual(results, [j * 2 for j in range(37)])
        self.assertEqual(lines.getvalue().split('\n')[-2], 'progress: 40/40')   # the 3 jobs before, then all 37 of these


if __name__ == '__main__':
    unittest.main()
