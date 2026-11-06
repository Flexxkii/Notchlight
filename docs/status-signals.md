# Local status signals

Notchlight 1.3 adds an attention indicator and a local command for your scripts.
These signals temporarily use the full border. Allowance data and widgets keep
their normal meaning; dismissing or expiring a signal restores the usage border.
The master **Show border** switch always wins. An active signal can appear while
**Show only while working** is enabled, even when Codex is idle.

## Codex attention

In **Settings → Status signals**, enable **Show when Codex needs attention** and
choose **Set Up Codex Hooks…** from the packaged app in its permanent location.
The installer merges Notchlight's entries into `$CODEX_HOME/hooks.json` (or
`~/.codex/hooks.json`), preserves unrelated entries, and saves a backup before
changing an existing file. It never edits authentication or hook trust records.

In Codex, use `/hooks` to review and trust the new hooks, then start a new chat.
Codex may skip hooks until this review is complete. Move the app before setup;
if you move it afterward, rerun setup and review the changed hook commands.

An explicit `PermissionRequest` or a synchronous `request_user_input` call adds
an amber **Needs attention** state. A new model request or turn stop clears that
turn's signal. A new user prompt, interruption, or session end clears the session.
Other sessions and custom signals are not cleared. The label says **requested**:
an automatically handled approval may appear briefly, and a request can remain
until the model resumes. Dismiss it from the notch menu or Settings if needed.
Abandoned requests expire after one hour rather than remaining indefinitely.

No timeout or inactive task is interpreted as an approval request. Asynchronous
input tools, remote-only chats, untrusted hooks, and tool paths without lifecycle
hooks are not detected. This is a status indicator; it never approves, rejects,
or answers a request. Open Codex to respond.

Only opaque session/turn correlation hashes, fixed status text, and timestamps
are saved. Hook input can contain tool arguments in memory, but the helper does
not save, log, or forward those arguments or read the transcript path.

Hook schema and coverage: [official Codex hook documentation](https://learn.chatgpt.com/docs/hooks).

## Custom commands

Enable **Allow custom local signals**, then choose **Install Command…**. This
creates `~/.local/bin/notchlight` pointing to the helper inside the packaged app.
An existing unrelated file is never replaced. Use the full path below, or add
`~/.local/bin` to your shell's `PATH` yourself.

```sh
~/.local/bin/notchlight signal --source build --state working --message 'Building…' --ttl 600
~/.local/bin/notchlight signal --source build --state success --message 'Build passed' --ttl 30
~/.local/bin/notchlight signal --source tests --state failure --message 'Tests failed' --ttl 300
~/.local/bin/notchlight clear --source build
~/.local/bin/notchlight list
```

For a shell workflow, preserve the command's result:

```sh
~/.local/bin/notchlight signal --source tests --state working --message 'Running tests' --ttl 1800
if swift test; then
    ~/.local/bin/notchlight signal --source tests --state success --message 'Tests passed' --ttl 30
else
    task_exit=$?
    ~/.local/bin/notchlight signal --source tests --state failure --message 'Tests failed' --ttl 300
    exit "$task_exit"
fi
```

States are `working` (your working color and pulse), `success` (green), `failure`
(red), and `attention` (amber). Hover text and Settings name the state, so color
is not the only explanation. Priority is attention, failure, working, success;
the newest signal wins within a priority. Up to 128 independent sources can be
stored. A source replaces only its own signal.

Source names are case-insensitive and allow 1–80 ASCII letters, digits, hyphens,
and underscores; `codex-` is reserved. Messages allow 1–120 characters (up to
1024 UTF-8 bytes) without control characters. The
default lifetime is 300 seconds; `--ttl` accepts 1–86400 seconds. Long messages
are available in Settings even when they don't fit beside the notch.

Commands do not launch the app. Active unexpired signals are loaded when it
starts. Disabling custom signals hides them; it does not modify your scripts.
Signals are local, same-user files in
`~/Library/Application Support/Notchlight/Signals/`, protected by directory and
file permissions. There is no network listener or URL-triggered command runner.
Expired/invalid files are removed on the next signal write. `clear` and the
Dismiss buttons remove a source immediately. You can remove the whole Signals
folder after quitting to erase all stored signals.

## Battery-aware effects

Enable **Settings → Battery-aware effects → Reduce effects on battery or in Low
Power Mode**. On battery power or while Low Power Mode is enabled, Notchlight
stops continuous pulsing, removes the border's glow, and uses static notch
transitions. Usage, signal colors, hover details, and accessibility remain
available. Returning to external power with Low Power Mode off restores your
saved appearance. The setting is opt-in and does not alter macOS power settings.

Power changes use system notifications, not a polling timer. This reduces
optional rendering work; it is not a quantified battery-life claim.
