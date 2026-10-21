#!/usr/bin/env python3
"""Run a session-leading Herdr child without detaching from launchd.

Usage: fm-remote-herdr-session.py <herdr-path> server --session <name>
The waiting parent retains launchd's job identity and forwards termination;
setsid changes the POSIX session, not the inherited macOS Aqua audit session.
"""

import os
import signal
import sys


def main():
    if len(sys.argv) != 5 or sys.argv[2:4] != ["server", "--session"]:
        sys.exit("usage: fm-remote-herdr-session.py <herdr-path> server --session <name>")
    # Block termination across fork so a stop cannot orphan the new child.
    signals = {signal.SIGTERM, signal.SIGINT, signal.SIGHUP}
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
    child = os.fork()
    if child == 0:
        os.setsid()
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)
        os.execv(sys.argv[1], sys.argv[1:])

    def forward(signum, _frame):
        try:
            os.kill(child, signum)
        except ProcessLookupError:
            pass

    for signum in signals:
        signal.signal(signum, forward)
    signal.pthread_sigmask(signal.SIG_SETMASK, previous)
    _, status = os.waitpid(child, 0)
    code = os.waitstatus_to_exitcode(status)
    return code if code >= 0 else 128 - code


if __name__ == "__main__":
    sys.exit(main())
