# Workspace change monitoring

Orkhon refreshes open files, expanded folders and visible previews when the
workspace changes. Every extension is included, including extensionless files,
Git-untracked files, hidden files and build outputs. There is no extension list
or dependency parser in the watcher.

## Timing and scope

- **Typing:** 250 ms after the last edit, with a one-second maximum scheduling delay.
- **Filesystem events:** one second after the last notification, with a three-second
  maximum scheduling delay while notifications keep arriving.
- These bounds apply to scheduling after event delivery. Operating-system event
  delivery, network transfers and rendering can take additional time.
- The selected workspace is recursive. Open files outside it remain monitored.
- Only visible previews render. Hidden tabs record a resource revision and load
  current assets when shown. Creating a watcher never creates a WebKit view.
- Tree refreshes preserve expansion and selection. Collapsed sidebars wait until
  shown, and remote listings refresh only expanded directories.
- A refresh can reload HTML scripts and reset page state. Scroll position is
  retained where possible. Source buffers and unsaved edits are preserved.

Orkhon's own temporary preview/SSH files and recovery data do not trigger a
refresh loop. Directory symlinks do not widen recursive monitoring outside the
selected roots. Explicitly opening a resolved file outside the workspace adds
its parent as an additional root.

## Local implementation

One FSEvents stream covers each window's workspace roots, without walking the
repository or hashing it while idle. Direct vnode notifications for open files
and their parents preserve prompt buffer/conflict updates, including atomic
replacement, even when macOS batches its recursive notifications.

Events reconcile open buffers using the existing merge machinery. A resolved
conflict remains ordinary source text. HTML resources are invalidated on a
filesystem revision, and Markdown images receive a revision URL; updating an
asset does not require editing the parent document.

## SSH implementation

The authenticated OpenSSH connection carries one persistent event channel per
window. The bundled Python helper is passed as a command, installs no files or
packages on the server, and uses only Python's standard library:

- Linux: inotify, one kernel watch per directory.
- macOS: FSEvents, through the system framework.
- Python 3 is required for remote event monitoring; editing and terminals can
  still operate without it.

The helper subscribes before enumerating children, adds watches for new/moved
folders, avoids directory symlink loops, and exits when channel stdin closes.
Queue overflow or loss of the workspace root ends the channel so reconnect can
establish a fresh baseline. Notifications contain only fixed protocol words,
not filenames or document contents. Idle channels do not hash repository data.

When events arrive, one batched checksum request reconciles open remote files;
only changed document contents are downloaded. Relative Markdown images and
HTML CSS/JavaScript are fetched on demand over the authenticated connection,
with bounded reads and at most four simultaneous resource requests. HTML uses
a separate custom WebKit origin; browser APIs requiring an HTTP(S) origin,
such as service workers, are not provided by this static-file preview.

If the helper or event channel is unavailable, the sidebar reports a ten-second
fallback refresh. Orkhon retries the event channel with bounded backoff and
reconciles changes made during the outage. It never recursively hashes the
repository. Network filesystems may not report writes made from other machines;
use Refresh or refocus the editor to reconcile open files in that case.

## Reproduce the tests

Run these on a logged-in macOS desktop, outside a GUI-restricted sandbox:

```sh
make build
make verify
python3 scripts/stress_workspace_watch.py
python3 scripts/benchmark.py
```

`test_workspace_watch.py` exercises the actual helper with deep edits, arbitrary
extensions, atomic saves, new and renamed directories, deletion, symlink loops,
read-only access and channel cleanup. `stress_workspace_watch.py` creates 5,000
files in 201 directories, generates three bursts of 2,200 changes, verifies idle
silence and opens/closes ten watcher processes. Both scripts also run on Linux;
the repository's Linux CI runs them without SSH or external services.

For end-to-end remote tests, provision a **disposable localhost-only** Linux SSH
server with Python 3 and a dedicated test key. The fixture writes only within
that container's `/workspace` and `/preview-stress`; never point these tests at
a personal or production server.

```sh
swiftc -O Sources/Lumen/RemoteWorkspace.swift scripts/stress_remote_events.swift \
  -o work/stress-remote-events
work/stress-remote-events PORT /absolute/path/to/test-key Resources/workspace_watch.py

ORKHON_TEST_REMOTE_ONLY=1 ORKHON_TEST_SSH_PORT=PORT \
  ORKHON_TEST_SSH_KEY=/absolute/path/to/test-key \
  python3 scripts/test_integration.py
```

The SSH tests use their own control socket and known-hosts file. They exercise
real multiplexed SSH, 6,600 changes, latest-file reconciliation, ten channel
cycles, abrupt disconnect, idle CPU/RSS and orphan cleanup. The native UI test
also verifies preview assets, unsaved buffers, event-channel recovery, conflict
resolution and UI responsiveness during a sustained remote burst.

Launch benchmarking stops on its first failed launch. A desktop-session failure
is an invalid measurement, not a reason to repeatedly launch a crashing process.
