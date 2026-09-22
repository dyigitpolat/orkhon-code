#!/usr/bin/env python3
"""Orkhon SSH event helper: stdlib only, no installation and no file contents.

A persistent stdin is its lifetime lease. EOF/disconnect stops it. stdout is a
bounded line protocol (ready/change); it never emits paths or terminal escapes.
Linux uses inotify, macOS uses FSEvents. Other hosts use the client's bounded
fallback rather than silently pretending event notifications are available.
"""
import ctypes
import os
import select
import struct
import sys
import time


class Unavailable(Exception):
    pass


def emit(message):
    print(message, flush=True)


def ignored(path):
    path = path[8:] if path.startswith('/private/') else path
    return path.startswith('/tmp/orkhon-ssh-') or path.startswith('/tmp/orkhon-preview-')


def roots_from(paths):
    roots = []
    for path in sorted({os.path.realpath(p) for p in paths}, key=len):
        if not any(path == r or path.startswith(r.rstrip('/') + '/') for r in roots):
            roots.append(path)
    if not roots or not all(os.path.isdir(p) for p in roots):
        raise Unavailable('Workspace directory unavailable')
    return roots


def linux(roots):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.inotify_init1.argtypes = [ctypes.c_int]
    libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    libc.inotify_rm_watch.argtypes = [ctypes.c_int, ctypes.c_int]
    fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
    if fd < 0:
        raise Unavailable('inotify unavailable')
    watches, paths = {}, {}
    # MODIFY/ATTRIB/CLOSE_WRITE/MOVE/CREATE/DELETE/DELETE_SELF/MOVE_SELF.
    # Never subscribe to ACCESS/OPEN/CLOSE_NOWRITE: preview reads aren't edits.
    mask = 0x00000FCE | 0x01000000 | 0x02000000  # ONLYDIR, DONT_FOLLOW

    def add_tree(root):
        pending = [root]
        while pending:
            path = pending.pop()
            if ignored(path) or os.path.islink(path):
                continue
            if path not in paths:
                wd = libc.inotify_add_watch(fd, os.fsencode(path), mask)
                if wd < 0:
                    error = ctypes.get_errno()
                    if error == 2:  # Concurrent removal; the parent is watched.
                        continue
                    raise Unavailable('A directory cannot be watched')
                old = watches.get(wd)
                if old is not None:
                    paths.pop(old, None)
                watches[wd], paths[path] = path, wd
            try:
                with os.scandir(path) as entries:
                    pending.extend(e.path for e in entries if e.is_dir(follow_symlinks=False))
            except FileNotFoundError:
                pass
            except PermissionError:
                raise Unavailable('A directory cannot be read')

    def remove_tree(root):
        for path, wd in list(paths.items()):
            if path == root or path.startswith(root + '/'):
                libc.inotify_rm_watch(fd, wd)
                watches.pop(wd, None)
                paths.pop(path, None)

    try:
        for root in roots:
            add_tree(root)
        emit('ready')
        changed, last_emit = False, 0.0
        while True:
            readable, _, _ = select.select([fd, sys.stdin], [], [], 0.1 if changed else None)
            if sys.stdin in readable and not os.read(sys.stdin.fileno(), 4096):
                return
            if fd in readable:
                data = os.read(fd, 256 * 1024)
                offset, rebuild = 0, False
                while offset + 16 <= len(data):
                    wd, flags, cookie, length = struct.unpack_from('iIII', data, offset)
                    name = os.fsdecode(data[offset + 16:offset + 16 + length].split(b'\0', 1)[0])
                    offset += 16 + length
                    if flags & 0x00004000:  # Queue overflow: establish a fresh baseline.
                        rebuild = True
                        changed = True
                        continue
                    parent = watches.get(wd)
                    if parent is None:
                        continue
                    path = os.path.join(parent, name) if name else parent
                    if ignored(path):
                        continue
                    changed = True
                    if flags & 0x00008000:  # IN_IGNORED
                        watches.pop(wd, None)
                        paths.pop(parent, None)
                    if flags & 0x40000000:  # Directory structure changes.
                        if flags & (0x00000040 | 0x00000200):
                            remove_tree(path)
                        if flags & (0x00000080 | 0x00000100):
                            add_tree(path)
                    if parent in roots and flags & (0x00000400 | 0x00000800):
                        raise Unavailable('Workspace root moved; reconnect watcher')
                if rebuild:
                    # Recreate the descriptor to discard stale watch IDs/events.
                    raise Unavailable('Event queue overflow; reconnect and reconcile')
            now = time.monotonic()
            if changed and now - last_emit >= 0.1:
                emit('change')
                last_emit, changed = now, False
    finally:
        os.close(fd)


def macos(roots):
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    fs = ctypes.CDLL('/System/Library/Frameworks/CoreServices.framework/Frameworks/FSEvents.framework/FSEvents')
    ptr = ctypes.c_void_p
    cf.CFStringCreateWithCString.argtypes = [ptr, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFStringCreateWithCString.restype = ptr
    cf.CFArrayCreate.argtypes = [ptr, ctypes.POINTER(ptr), ctypes.c_long, ptr]
    cf.CFArrayCreate.restype = ptr
    cf.CFRelease.argtypes = [ptr]
    callback_type = ctypes.CFUNCTYPE(None, ptr, ptr, ctypes.c_size_t, ptr, ptr, ptr)
    fs.FSEventStreamCreate.argtypes = [ptr, callback_type, ptr, ptr, ctypes.c_uint64, ctypes.c_double, ctypes.c_uint32]
    fs.FSEventStreamCreate.restype = ptr
    fs.FSEventStreamStart.argtypes = [ptr]
    fs.FSEventStreamStart.restype = ctypes.c_bool
    for name in ('FSEventStreamStop', 'FSEventStreamInvalidate', 'FSEventStreamRelease'):
        getattr(fs, name).argtypes = [ptr]
    strings = [cf.CFStringCreateWithCString(None, os.fsencode(p), 0x08000100) for p in roots]
    array = cf.CFArrayCreate(None, (ptr * len(strings))(*strings), len(strings), None)
    dispatch = ctypes.CDLL('/usr/lib/system/libdispatch.dylib')
    dispatch.dispatch_queue_create.argtypes = [ctypes.c_char_p, ptr]
    dispatch.dispatch_queue_create.restype = ptr
    dispatch.dispatch_release.argtypes = [ptr]
    queue = dispatch.dispatch_queue_create(b'app.orkhon.ssh-events', None)
    fs.FSEventStreamSetDispatchQueue.argtypes = [ptr, ptr]
    sync_callback_type = ctypes.CFUNCTYPE(None, ptr)
    dispatch.dispatch_sync_f.argtypes = [ptr, ptr, sync_callback_type]
    @sync_callback_type
    def drained(context):
        pass
    wake_read, wake_write = os.pipe()
    os.set_blocking(wake_write, False)
    def wake():
        try:
            os.write(wake_write, b'x')
        except BlockingIOError:
            pass
    pending = [False]
    rebuild = [False]

    @callback_type
    def callback(stream, context, count, raw_paths, flags, ids):
        paths = ctypes.cast(raw_paths, ctypes.POINTER(ctypes.c_char_p))
        event_flags = ctypes.cast(flags, ctypes.POINTER(ctypes.c_uint32))
        if any(event_flags[i] & 0x20 for i in range(count)):  # RootChanged
            rebuild[0] = True
            wake()

        if not pending[0] and any(not ignored(os.fsdecode(paths[i])) for i in range(count)):
            pending[0] = True
            wake()

    stream = fs.FSEventStreamCreate(None, callback, None, array, 0xFFFFFFFFFFFFFFFF, 0.1, 0x16)
    try:
        if not stream:
            raise Unavailable('FSEvents unavailable')
        fs.FSEventStreamSetDispatchQueue(stream, queue)
        if not fs.FSEventStreamStart(stream):
            raise Unavailable('FSEvents cannot watch this workspace')
        emit('ready')
        last_emit = 0.0
        while not rebuild[0]:
            delay = max(0, 0.1 - (time.monotonic() - last_emit)) if pending[0] else None
            readable, _, _ = select.select([sys.stdin, wake_read], [], [], delay)
            if wake_read in readable:
                os.read(wake_read, 4096)
            if sys.stdin in readable and not os.read(sys.stdin.fileno(), 4096):
                break
            if pending[0] and time.monotonic() - last_emit >= 0.1:
                pending[0] = False
                emit('change')
                last_emit = time.monotonic()
        if rebuild[0]:
            raise Unavailable("Workspace root changed; reconnect watcher")
    finally:
        if stream:
            fs.FSEventStreamStop(stream)
            fs.FSEventStreamInvalidate(stream)
            fs.FSEventStreamRelease(stream)
        dispatch.dispatch_sync_f(queue, None, drained)
        os.close(wake_read);os.close(wake_write)
        dispatch.dispatch_release(queue)
        cf.CFRelease(array)
        for value in strings:
            cf.CFRelease(value)


def main():
    roots = roots_from(sys.argv[1:])
    if sys.platform.startswith('linux'):
        linux(roots)
    elif sys.platform == 'darwin':
        macos(roots)
    else:
        raise Unavailable('This server has no supported event API')


if __name__ == '__main__':
    try:
        main()
    except (Unavailable, OSError, AttributeError):
        # No server paths, credentials or terminal control text crosses protocol.
        sys.exit(75)
