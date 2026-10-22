"""NSP packer progress regressions using only the standard library, without games, keys or build tools."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'build_ipa_from_nsp.py'
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', SCRIPT)
packer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packer)


class JsonProgress(unittest.TestCase):
    def setUp(self):
        self.out = io.StringIO()
        self.redirect = contextlib.redirect_stdout(self.out)
        self.redirect.__enter__()
        self.addCleanup(self.redirect.__exit__, None, None, None)
        self.progress = packer.Progress('json')
        self.addCleanup(self.progress.close)
        patch = mock.patch.object(packer, 'PROG', self.progress)
        patch.start()
        self.addCleanup(patch.stop)
        self.now = 100.0
        patch = mock.patch.object(packer.time, 'monotonic', side_effect=lambda: self.now)
        patch.start()
        self.addCleanup(patch.stop)

    def events(self, kind=None):
        text = self.out.getvalue()
        self.assertNotIn('\r', text)
        self.assertNotIn('\x1b', text)
        self.assertTrue(not text or text.endswith('\n'))
        events = [json.loads(line) for line in text.splitlines()]
        for event in events:
            self.assertIsInstance(event, dict)
            self.assertIsInstance(event['t'], (int, float))
        return [e for e in events if kind is None or e['ev'] == kind]

    def test_unicode_and_embedded_newlines(self):
        name = 'extract \u65e5\u672c\u8a9e \U0001f3ae'
        self.progress.stage(name, step='read \u03a9')
        self.progress.say('shader split \u2713\nsecond line\r\t"quoted"')
        self.progress.end('3 files \u2014 ready')
        events = self.events()
        self.assertEqual([e['ev'] for e in events], ['stage', 'progress', 'say', 'stage_end'])
        self.assertEqual(events[0]['name'], name)
        self.assertEqual(events[2]['msg'], 'shader split \u2713\nsecond line\r\t"quoted"')
        self.assertEqual(events[-1]['summary'], '3 files \u2014 ready')
        self.assertIn(name, self.out.getvalue())   # Unicode is not needlessly ASCII-escaped

    def test_event_contract_and_stage_lifecycle(self):
        self.progress.plan(1)
        self.progress.stage('extract', step='reading', done=0, total=10, unit='files', est=True)
        self.progress.set(step='writing', done=2, total=4, unit='B', note='packing')
        self.progress.end('4 bytes')
        self.progress.add(1)
        self.progress.stage('rewrite')
        self.progress.close(ok=False)
        self.progress.close(ok=False)   # no duplicate stage_end
        events = self.events()
        self.assertEqual([e['ev'] for e in events], [
            'stage', 'progress', 'step', 'progress', 'stage_end', 'stage', 'progress', 'stage_end'])
        self.assertEqual({k: events[0][k] for k in ('k', 'n', 'name', 'step')},
                         {'k': 1, 'n': 1, 'name': 'extract', 'step': 'reading'})
        self.assertEqual(set(events[1]), {'ev', 't', 'k', 'name', 'step', 'done', 'total', 'unit', 'est', 'note', 'frac', 'eta', 'elapsed'})
        self.assertEqual(events[1]['frac'], 0)
        self.assertTrue(events[1]['est'])
        self.assertEqual({k: events[2][k] for k in ('ev', 'k', 'name', 'step')},
                         {'ev': 'step', 'k': 1, 'name': 'extract', 'step': 'writing'})
        self.assertEqual(events[3]['frac'], 0.5)
        self.assertFalse(events[3]['est'])   # step changes reset metadata and history
        self.assertTrue(events[4]['ok'])
        self.assertEqual(events[4]['summary'], '4 bytes')
        self.assertEqual((events[5]['k'], events[5]['n']), (2, 2))
        self.assertFalse(events[-1]['ok'])
        self.assertEqual(events[-1]['summary'], '')
        self.assertGreaterEqual(events[-1]['elapsed'], 0)

    def test_new_stage_ends_previous_stage_once(self):
        self.progress.stage('first')
        self.progress.stage('second')
        self.progress.end()
        ends = self.events('stage_end')
        self.assertEqual([e['name'] for e in ends], ['first', 'second'])
        self.assertTrue(all(e['ok'] for e in ends))

    def test_unknown_and_zero_totals_are_not_fabricated(self):
        self.progress.stage('survey', done=0)
        self.now += 1
        self.progress.set(done=7)
        self.progress.end()
        events = self.events('progress')
        self.assertEqual([e['done'] for e in events], [0, 7])
        for event in events:
            self.assertIsNone(event['total'])
            self.assertIsNone(event['frac'])
            self.assertIsNone(event['eta'])
        self.progress.stage('empty', done=0, total=0)
        event = self.events('progress')[-1]
        self.assertEqual(event['total'], 0)
        self.assertIsNone(event['frac'])
        self.assertIsNone(event['eta'])

    def test_step_resets_count_metadata_and_eta(self):
        self.progress.stage('compile', step='objects', done=10, total=20, unit='files', est=True, note='old')
        self.progress.set(step='packing')
        self.progress.set(step='packing')   # unchanged step is not another lifecycle event
        event = self.events('progress')[-1]
        self.assertEqual(len(self.events('step')), 1)
        self.assertEqual(event['step'], 'packing')
        self.assertIsNone(event['done'])
        self.assertIsNone(event['total'])
        self.assertIsNone(event['frac'])
        self.assertIsNone(event['eta'])
        self.assertEqual((event['unit'], event['est'], event['note']), ('', False, ''))

    def test_count_throttle_and_final_snapshot(self):
        self.progress.stage('compile', done=0, total=100)
        for done in range(1, 50):
            self.progress.set(done=done)
        self.assertEqual([e['done'] for e in self.events('progress')], [0])
        self.now += 0.5
        self.progress.set(done=50)
        self.assertEqual([e['done'] for e in self.events('progress')], [0, 50])
        self.progress.set(done=100)
        self.progress.end()
        events = self.events()
        self.assertEqual([e['done'] for e in self.events('progress')], [0, 50, 100])
        self.assertEqual(events[-2]['frac'], 0.99)   # only stage_end confirms completion
        self.assertEqual(events[-1]['ev'], 'stage_end')
        self.assertTrue(events[-1]['ok'])

    def test_unchanged_snapshots_are_not_repeated(self):
        self.progress.stage('compile', done=0)
        self.now += 10
        self.progress.set(done=0)
        self.progress.set()
        self.progress.end()
        self.assertEqual(len(self.events('progress')), 1)

    def test_all_metadata_changes_bypass_count_throttle(self):
        self.progress.stage('compile', done=0)
        changes = [('total', 20), ('unit', 'files'), ('est', True), ('note', 'arm64'),
                   ('total', 30), ('unit', 'B'), ('est', False), ('note', '')]
        for index, (key, value) in enumerate(changes, 2):
            self.progress.set(**{key: value})
            events = self.events('progress')
            self.assertEqual(len(events), index, (key, value))
            self.assertEqual(events[-1][key], value)
            self.assertEqual(events[-1]['done'], 0)
        self.progress.set(done=1)   # pending count travels with the next metadata event
        self.progress.set(note='latest')
        self.assertEqual(self.events('progress')[-1]['done'], 1)

    def test_eta_is_seconds_when_rate_is_known(self):
        with mock.patch.object(packer.time, 'time', return_value=1000):
            self.progress.stage('extract', done=0, total=100)
        self.now += 5
        with mock.patch.object(packer.time, 'time', return_value=1005):
            self.progress.set(done=25)
        event = self.events('progress')[-1]
        self.assertEqual(event['eta'], 15)
        self.assertEqual(event['elapsed'], 5)

    def test_close_preserves_json_for_late_diagnostics(self):
        self.progress.stage('rewrite')
        self.progress.close(ok=False)
        self.progress.say('[RED] failed\nlog tail')
        self.assertEqual(self.progress.mode, 'json')
        self.assertEqual([e['ev'] for e in self.events()], ['stage', 'progress', 'stage_end', 'say'])

    def test_json_has_no_drawing_ticker(self):
        with mock.patch.object(packer.threading, 'Thread') as thread:
            self.progress.stage('extract')
            thread.assert_not_called()
        self.assertIsNone(self.progress.ticker)

    def test_stale_poll_cannot_write_after_stage_end(self):
        self.progress.stage('first')
        st = self.progress.cur
        stop = threading.Event()
        st.pstop = stop
        def poll():
            self.progress.stage('second')
            return {'done': 999, 'step': 'stale'}
        self.progress._poll(st, poll, stop)
        self.assertTrue(stop.is_set())
        self.assertFalse(any(e.get('done') == 999 or e.get('step') == 'stale' for e in self.events()))
        self.assertEqual(self.events()[-1]['name'], 'second')

    def test_cli_success(self):
        def build(args):
            self.assertEqual(args.progress, 'json')
            self.progress.stage('synthetic')
            self.progress.end('ready')
            packer.say('done')
        with mock.patch.object(packer, 'main', side_effect=build):
            self.assertEqual(packer.cli(['--progress', 'json']), 0)
        self.assertTrue(self.events('stage_end')[-1]['ok'])
        self.assertEqual(self.events()[-1]['ev'], 'say')

    def test_cli_errors_and_interrupts_end_stage_and_emit_json(self):
        for error, code, message in ((packer.BuildError('tool failed'), 1, 'tool failed'),
                                     (KeyboardInterrupt(), 130, 'interrupted')):
            with self.subTest(error=type(error).__name__):
                self.out.seek(0); self.out.truncate()
                def build(args):
                    self.progress.stage('synthetic')
                    raise error
                with mock.patch.object(packer, 'main', side_effect=build):
                    self.assertEqual(packer.cli(['--progress', 'json']), code)
                self.assertEqual(len(self.events('stage_end')), 1)
                self.assertFalse(self.events('stage_end')[0]['ok'])
                self.assertIn(message, self.events()[-1]['msg'])

    def test_unexpected_exception_keeps_traceback_semantics_and_json_diagnostic(self):
        def build(args):
            self.progress.stage('synthetic')
            raise OSError('disk failure')
        with mock.patch.object(packer, 'main', side_effect=build):
            with self.assertRaisesRegex(OSError, 'disk failure'):
                packer.cli(['--progress', 'json'])
        self.assertFalse(self.events('stage_end')[-1]['ok'])
        self.assertIn('OSError: disk failure', self.events()[-1]['msg'])

    def test_json_never_prompts_even_with_keyboard_or_ipython(self):
        with mock.patch.object(packer, 'in_ipython', return_value=True), mock.patch('builtins.input') as prompt:
            with self.assertRaisesRegex(packer.BuildError, 'JSON mode does not prompt'):
                packer.ask('NSP folder: ', 'NSP folder')
            prompt.assert_not_called()
        self.assertEqual(self.events(), [])

    def test_child_failure_tail_is_a_single_say_event(self):
        with tempfile.TemporaryDirectory(prefix='progress_test_') as tmp:
            log = Path(tmp) / 'child.log'
            self.progress.stage('child')
            child = 'import sys; print("line one"); print("line two", file=sys.stderr); sys.exit(7)'
            with self.assertRaisesRegex(packer.BuildError, 'exit code 7'):
                packer.run([sys.executable, '-c', child], log)
            self.assertIn('line one', log.read_text())
            self.assertIn('line two', log.read_text())
        self.assertFalse(self.events('stage_end')[-1]['ok'])
        messages = self.events('say')
        self.assertEqual(len(messages), 1)
        self.assertIn('line one', messages[0]['msg'])
        self.assertIn('line two', messages[0]['msg'])

    def test_child_success_output_is_logged_not_stdout(self):
        with tempfile.TemporaryDirectory(prefix='progress_test_') as tmp:
            log = Path(tmp) / 'child.log'
            packer.run([sys.executable, '-c', 'print("not a JSON event")'], log)
            self.assertEqual(log.read_text(), 'not a JSON event\n')
        self.assertEqual(self.events(), [])


class ModesAndCli(unittest.TestCase):
    def test_explicit_modes_and_parser_choices(self):
        for mode in ('bar', 'lines', 'off', 'json', 'auto'):
            self.assertEqual(packer.parse_args(['--progress', mode]).progress, mode)
            if mode != 'auto': self.assertEqual(packer.progress_mode(mode), mode)
        with self.assertRaises(packer.BuildError): packer.progress_mode('invalid')
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as caught:
                packer.parse_args(['--progress', 'invalid'])
        self.assertEqual(caught.exception.code, 2)

    def test_auto_mode_terminal_pipe_and_spyder(self):
        for ipython, tty, mode in ((False, False, 'lines'), (False, True, 'bar'), (True, False, 'bar')):
            with mock.patch.object(packer, 'in_ipython', return_value=ipython), mock.patch.object(packer.sys, 'stdout') as out:
                out.isatty.return_value = tty
                self.assertEqual(packer.progress_mode('auto'), mode)

    def test_human_modes_still_draw_or_print_stage_and_end(self):
        for mode in ('bar', 'lines', 'off'):
            with self.subTest(mode=mode), contextlib.redirect_stdout(io.StringIO()) as out:
                progress = packer.Progress(mode)
                try:
                    progress.plan(1)
                    progress.stage('compile', done=0, total=10)
                    progress.set(step='writing', done=1)
                    progress.say('message')
                    progress.close()
                finally:
                    ticker = progress.ticker
                    progress.close()
                    if ticker: ticker.join(2)
                text = out.getvalue()
                self.assertIn('[1/1] compile', text)
                self.assertIn('message', text)
                self.assertIn('\u2713 [1/1] compile', text)
                self.assertEqual('\r' in text, mode == 'bar')
                self.assertEqual('compile \u00b7 writing' in text, mode != 'off')

    def test_stopped_ticker_cannot_draw_on_reused_progress(self):
        progress = packer.Progress('bar')
        stop = threading.Event()
        class StopAfterWake:
            def wait(self, timeout):
                stop.set()   # simulates close() after wait returned but before the lock was acquired
                return False
            def is_set(self): return stop.is_set()
        progress.mode = 'json'
        progress.cur = object()   # any stale redraw would fail or call the mocked _draw
        with mock.patch.object(progress, '_draw') as draw:
            progress._tick(StopAfterWake())
            draw.assert_not_called()

    def test_ticker_close_and_restart_use_separate_stop_events(self):
        progress = packer.Progress('bar')
        with contextlib.redirect_stdout(io.StringIO()):
            progress.stage('first')
            first, stop = progress.ticker, progress.tstop
            progress.close()
            progress.stage('second')
            second = progress.ticker
            self.assertTrue(stop.is_set())
            self.assertIsNot(first, second)
            progress.close()
            first.join(2); second.join(2)
        self.assertFalse(first.is_alive())
        self.assertFalse(second.is_alive())

    def run_cli(self, *args):
        return subprocess.run([sys.executable, '-B', str(SCRIPT), *args], capture_output=True, text=True, timeout=15)

    def test_real_cli_failure_is_json_without_games_keys_or_dependencies(self):
        with tempfile.TemporaryDirectory(prefix='progress_test_') as tmp:
            result = self.run_cli('--progress=json', str(Path(tmp) / 'missing'), '-k', str(Path(tmp) / 'keys'))
        self.assertEqual(result.returncode, 1, result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertTrue(events)
        self.assertTrue(all(e['ev'] == 'say' for e in events))
        self.assertIn('[RED] not a folder:', events[-1]['msg'])
        self.assertEqual(result.stderr, '')

    def test_argument_failure_only_uses_stderr_and_help_is_human_readable(self):
        result = self.run_cli('--progress', 'json', '--not-an-option')
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, '')
        self.assertIn('unrecognized arguments', result.stderr)
        result = self.run_cli('--progress', 'json', '--help')
        self.assertEqual(result.returncode, 0)
        self.assertIn('json', result.stdout)
        self.assertIn('newline-delimited JSON', result.stdout)


if __name__ == '__main__':
    unittest.main()
