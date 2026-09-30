#!/usr/bin/env python3
"""Run a command on a terminal and type a password when sudo asks for one.

    with-password.py <password> <command> [args...]

The suite uses it to run install.sh the way a person does: in a terminal,
answering the one sudo prompt. Output is passed through; the exit status is
the command's.
"""
import os, pty, select, sys

password, argv = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)

seen = b""
answered = 0
while True:
    try:
        ready, _, _ = select.select([fd], [], [], 600)
        if not ready:
            break
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
    seen = (seen + data)[-200:]
    if b"password for" in seen.lower() and answered < 3:
        os.write(fd, password.encode() + b"\n")
        answered += 1
        seen = b""

_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
