#!/usr/bin/env python3
"""driver.py - type into wsl-setup.bat like a person: wait for each prompt,
then send the answer.

Wine's `set /p` grabs everything already waiting on stdin, so a pre-written
input file would be swallowed by the first prompt. Answering one prompt at a
time avoids that and matches how the script is really used.

Usage: driver.py OUTFILE REQDIR STEPS_JSON -- COMMAND...
STEPS_JSON is a list of [expect, answer]. expect is console text to wait for.
The special value "@PASSWORD" waits until proxy.exe asks for the two password
lines; the answer then holds both lines, joined by a newline.
"""
import json, os, subprocess, sys, threading, time

out_path, reqdir, steps = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
cmd = sys.argv[sys.argv.index("--") + 1:]
STEP_TIMEOUT = float(os.environ.get("E2E_STEP_TIMEOUT", "180"))

buf = bytearray()
lock = threading.Lock()
proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT)


def reader():
    with open(out_path, "wb") as f:
        while True:
            chunk = proc.stdout.read1(4096)
            if not chunk:
                return
            with lock:
                buf.extend(chunk)
            f.write(chunk); f.flush()


threading.Thread(target=reader, daemon=True).start()


def fail(msg):
    sys.stderr.write(f"driver: {msg}\n")
    proc.kill()
    sys.exit(3)


pos = 0
pw_seen = 0
for expect, answer in steps:
    deadline = time.time() + STEP_TIMEOUT
    while True:
        if expect == "@PASSWORD":
            n = len([f for f in os.listdir(reqdir) if f.startswith("stdin-wanted")])
            if n > pw_seen:
                pw_seen = n
                break
        else:
            with lock:
                i = bytes(buf).find(expect.encode(), pos)
            if i >= 0:
                pos = i + len(expect)
                break
        if proc.poll() is not None:
            time.sleep(0.5)  # let the reader drain
            fail(f"script exited (rc={proc.returncode}) while waiting for {expect!r}")
        if time.time() > deadline:
            fail(f"timed out waiting for {expect!r}")
        time.sleep(0.05)
    time.sleep(0.2)  # let the prompt's own ReadFile start before typing
    proc.stdin.write((answer + "\n").encode())
    proc.stdin.flush()

try:
    proc.wait(timeout=STEP_TIMEOUT)
except subprocess.TimeoutExpired:
    fail("script did not exit after the last answer")
time.sleep(0.5)
sys.exit(0)
