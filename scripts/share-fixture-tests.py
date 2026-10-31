#!/usr/bin/env python3
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request


SCRIPTS = Path(__file__).resolve().parent
FIXTURE_COMMAND = '''
set -euo pipefail
source "$1/share-fixture.sh"
trap share_fixture_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
share_fixture_start "$2" "$1/local-share-fixture.py" 'Fixture regression'
if [[ "$3" == repeat ]]; then
    original_pid="$share_fixture_pid"
    original_work_dir="$share_fixture_work_dir"
    original_url="$share_fixture_url"
    if share_fixture_start "$2" "$1/local-share-fixture.py" 'Repeated start'; then
        /bin/kill "$original_pid"
        wait "$original_pid" || true
        /bin/rm -rf "$original_work_dir"
        print -u2 'Repeated start replaced an active fixture.'
        exit 1
    fi
    [[ "$share_fixture_url" == "$original_url" ]]
fi
print -r -- "READY\t$share_fixture_url"
read -r finish
share_fixture_cleanup
'''


class Fixture:
    def __init__(self, directory, check_repeated_start=False):
        self.directory = directory
        directory.mkdir()
        self.marker = directory / 'caller-owned.txt'
        self.marker.write_text('keep')
        environment = os.environ.copy()
        environment['SNIP_SNAP_PYTHON'] = sys.executable
        self.process = subprocess.Popen(
            ['/bin/zsh', '-c', FIXTURE_COMMAND, 'fixture', str(SCRIPTS), str(directory),
             'repeat' if check_repeated_start else 'once'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=environment, start_new_session=True,
        )
        try:
            self.url = self.read_url()
        except BaseException:
            self.close(signal.SIGTERM)
            raise

    def read_url(self):
        pending = b''
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.process.stdout], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            chunk = os.read(self.process.stdout.fileno(), 4096)
            if not chunk:
                raise RuntimeError('Fixture exited before publishing its URL.')
            pending += chunk
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                if line.startswith(b'READY\t'):
                    return line.removeprefix(b'READY\t').decode()
        raise TimeoutError('Fixture did not publish its URL.')

    def close(self, signal_number=None):
        if self.process.poll() is None:
            if signal_number is None:
                self.process.stdin.write(b'finish\n')
                self.process.stdin.flush()
            else:
                self.process.send_signal(signal_number)
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait()
                raise
        for stream in [self.process.stdin, self.process.stdout, self.process.stderr]:
            stream.close()


class ShareFixtureTests(unittest.TestCase):
    def test_concurrent_fixtures_serve_independently_and_cleanup_only_their_owner(self):
        with tempfile.TemporaryDirectory(prefix='snipsnap-share-fixtures-') as directory:
            root = Path(directory)
            first = Fixture(root / 'first run', check_repeated_start=True)
            self.addCleanup(first.close)
            second = Fixture(root / 'second run')
            self.addCleanup(second.close)
            ports = []
            for fixture in [first, second]:
                url = urllib.parse.urlsplit(fixture.url)
                self.assertEqual((url.scheme, url.hostname, url.path), ('http', '127.0.0.1', '/'))
                self.assertGreater(url.port, 0)
                ports.append(url.port)
                with urllib.request.urlopen(fixture.url, timeout=3) as response:
                    self.assertIn(b'Snip Snap Share Fixture', response.read())
            self.assertNotEqual(*ports)
            first.close()
            self.assertEqual(first.process.returncode, 0)
            self.assertEqual(first.marker.read_text(), 'keep')
            self.assertEqual(list(first.directory.glob('share-fixture.*')), [])
            with self.assertRaises(urllib.error.URLError):
                urllib.request.urlopen(first.url, timeout=3)
            with urllib.request.urlopen(second.url, timeout=3) as response:
                self.assertIn(b'Snip Snap Share Fixture', response.read())
            second.close(signal.SIGTERM)
            self.assertEqual(second.process.returncode, 143)
            self.assertEqual(second.marker.read_text(), 'keep')
            self.assertEqual(list(second.directory.glob('share-fixture.*')), [])
            with self.assertRaises(urllib.error.URLError):
                urllib.request.urlopen(second.url, timeout=3)


if __name__ == '__main__':
    unittest.main()
