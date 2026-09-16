# Notchlight privacy policy

Version 1.0 · Effective 16 September 2026
Maintainer: Flexxkii (https://github.com/Flexxkii)
Contact: https://github.com/Flexxkii/notchlight/issues

## Local operation

Notchlight has no maintainer-operated backend, advertising SDK, analytics upload,
or automatic crash-report upload. The app does not send your settings, activity,
or diagnostic logs to Flexxkii. Its optional Codex integration communicates with
your installed Codex CLI; that CLI can contact OpenAI using your existing sign-in.
Local operation therefore does not mean that Codex makes no network requests.

## Settings

Appearance, connection preferences, and diagnostic preferences are stored in
macOS UserDefaults on your Mac. The packaged app uses the preferences domain
com.teodor.Notchlight. Settings remain until you change or remove them.

## Optional Codex integration

When you turn on Connect to Codex, Notchlight starts the installed Codex CLI's
local app-server to request account type and usage-window information. Account
responses may pass through process memory; Notchlight does not retain account
identifiers in its diagnostic logs. It does not directly open or store Codex
authentication tokens and does not make model-generation requests.

To infer whether Codex is working, Notchlight checks whether the desktop app is
running, reads its local task catalog, and examines local session files under
CODEX_HOME or ~/.codex. Those files can contain conversation content. The reader
examines file data in memory to locate lifecycle events; it retains lifecycle
state and timestamps, not conversation text or task titles. This is read-only
access to the Codex catalog and session files. It may not detect remote-only work.

Usage normally refreshes once per minute and activity approximately every two
seconds. Turning off Connect to Codex or quitting stops that monitoring.

## Optional Input Monitoring

Hide when swiping can request macOS Input Monitoring permission after you press
Allow. Its passive event tap inspects gesture type, direction classification,
and phase to hide the border during horizontal desktop swipes. It does not
record keystrokes, pointer coordinates, or ordinary mouse events. It does not
access the camera or microphone. Disable the feature in Notchlight or revoke
Input Monitoring in System Settings → Privacy & Security to stop this access.

## Local performance diagnostics

Diagnostics are enabled by default. Every two seconds they sample app CPU,
memory, I/O, page-ins, and wakeups, along with allowlisted app-state and timing
metadata. Logs can include app/build/OS versions, processor and memory capacity,
thermal and power state, timestamps, process/session identifiers, display and
accessibility context, and Codex connection/activity state. These measurements
help investigate performance; they are not uploaded automatically.

Logs exclude conversation text, task titles, authentication tokens, account
identifiers, raw RPC payloads, and absolute paths to Codex session files. They
are stored at ~/Library/Logs/Notchlight/Diagnostics/. While recording is active,
logs rotate with a target retention of at most 24 hours or 50 MiB. Cleanup runs
as part of recording; turning recording off or quitting does not delete old
logs or run a background cleanup service.

Settings → Diagnostics lets you stop recording, reveal logs, or export a ZIP.
An export contains raw measurements, environment metadata, and a readable
report. It stays where you save it until you delete it. Copies you share or
back up are outside Notchlight's control.

## Deletion and control

Disconnect Codex and disable diagnostics to stop those activities, or quit the
app. To remove diagnostic data, quit and delete the Diagnostics folder above
and any exported ZIPs. To remove saved preferences, quit and run
`defaults delete com.teodor.Notchlight` in Terminal. That resets all Notchlight
preferences, not just privacy choices. Deleting Notchlight does not delete your
Codex account, its sign-in, or its session files.

## Links and voluntarily shared information

Opening the repository or support links uses your browser and GitHub's service.
GitHub's privacy policy applies there. Information you choose to put in issues,
including screenshots and diagnostics, becomes visible to people with access
to that repository. Use the contact link for privacy questions without posting
sensitive information. Notchlight itself has no account database to search or
delete on your behalf.

## Changes

Future versions may update this policy to describe their behavior. The policy
bundled with this version describes this version. Any new data transmission or
permission must be disclosed when introduced; a policy edit alone does not
change what an installed version does.
