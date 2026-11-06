#!/usr/bin/env python3
"""Exercise the packaged helper with disposable, uniquely named local sources."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import uuid

helper = Path(sys.argv[1]).resolve()
folder = Path.home() / 'Library/Application Support/Notchlight/Signals'
source = 'validation-' + uuid.uuid4().hex
session, turn = str(uuid.uuid4()), str(uuid.uuid4())
digest = lambda value: hashlib.sha256(value.encode()).hexdigest()[:32]
hook_source = 'codex-' + digest(digest(session) + digest(turn))


def run(*args, **kwargs):
    return subprocess.run([str(helper), *args], capture_output=True, check=True, **kwargs)


try:
    run('signal', '--source', source, '--state', 'working', '--message', 'Validation build', '--ttl', '30')
    assert json.loads((folder / (source + '.json')).read_text())['state'] == 'working'
    run('signal', '--source', source, '--state', 'success', '--message', 'Validation passed', '--ttl', '10')
    assert json.loads((folder / (source + '.json')).read_text())['state'] == 'success'
    run('clear', '--source', source)
    assert not (folder / (source + '.json')).exists()
    rejected = subprocess.run([str(helper), 'signal', '--source', '../escape', '--state', 'failure',
                               '--message', 'No'], capture_output=True)
    assert rejected.returncode != 0
    event = {'session_id': session, 'turn_id': turn, 'hook_event_name': 'PermissionRequest',
             'tool_name': 'Bash', 'tool_input': {'command': 'fixture-only-sensitive'}}
    data = json.dumps(event).encode()
    process = subprocess.Popen([str(helper), 'codex-hook'], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    process.stdin.write(data[:23]); process.stdin.flush()
    process.stdin.write(data[23:]); process.stdin.close()
    output = process.stdout.read(); error = process.stderr.read()
    assert process.wait(timeout=5) == 0 and output.strip() == b'{}' and not error
    persisted = (folder / (hook_source + '.json')).read_text()
    assert 'fixture-only-sensitive' not in persisted and session not in persisted
    assert json.loads(persisted)['state'] == 'attention'
    event['hook_event_name'] = 'PreModelRequest'
    assert run('codex-hook', input=json.dumps(event).encode()).stdout.strip() == b'{}'
    assert not (folder / (hook_source + '.json')).exists()
    assert run('codex-hook', input=b'not-json').stdout.strip() == b'{}'
    print('Packaged command passed: write, replace, clear, invalid input, chunked hook input, private metadata, resume cleanup, and fail-open hook output.')
finally:
    for name in (source, hook_source):
        (folder / (name + '.json')).unlink(missing_ok=True)
