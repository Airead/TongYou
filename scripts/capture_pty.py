#!/usr/bin/env python3
"""
Capture raw PTY output from a command (e.g. opencode) for terminal debugging.
Auto-responds to common terminal queries so TUI apps render their full UI.

Usage:
    python3 dev/capture_pty.py [command] [args...]
    python3 dev/capture_pty.py --duration 5     # capture for 5 seconds

Output:
    dev/pty_capture.bin   — raw bytes
    dev/pty_capture.txt   — human-readable escape annotation
"""

import argparse
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time


def build_responses(rows: int, cols: int) -> list[tuple[bytes, bytes]]:
    """Build (pattern, response) pairs for terminal queries."""
    return [
        # OSC 11 — query background color
        (b"\x1b]11;?\x07", b"\x1b]11;rgb:0000/0000/0000\x1b\\"),
        # DSR 6n — cursor position report
        (b"\x1b[6n", f"\x1b[{rows};{cols}R".encode()),
        # DECRQM ?1016 — SGR mouse pixel mode (not set)
        (b"\x1b[?1016$p", b"\x1b[?1016;2$y"),
        # DECRQM ?2027 — grapheme cluster (not set)
        (b"\x1b[?2027$p", b"\x1b[?2027;2$y"),
        # DECRQM ?2031 — (not set)
        (b"\x1b[?2031$p", b"\x1b[?2031;2$y"),
        # DECRQM ?1004 — focus events (not set)
        (b"\x1b[?1004$p", b"\x1b[?1004;2$y"),
        # DECRQM ?2004 — bracketed paste (not set)
        (b"\x1b[?2004$p", b"\x1b[?2004;2$y"),
        # DECRQM ?2026 — synchronized output (not set)
        (b"\x1b[?2026$p", b"\x1b[?2026;2$y"),
        # XTVERSION
        (b"\x1b[>0q", b"\x1bP>|TongYouCapture(0.1)\x1b\\"),
        # Kitty keyboard protocol query
        (b"\x1b[?u", b"\x1b[?0u"),
        # Report window size in pixels (14t)
        (b"\x1b[14t", f"\x1b[4;{rows * 20};{cols * 10}t".encode()),
        # DA1 — primary device attributes
        (b"\x1b[c", b"\x1b[?62;22c"),
        # DA2 — secondary device attributes
        (b"\x1b[>c", b"\x1b[>0;0;0c"),
        # DECRQM ?996 — color theme query (not set)
        (b"\x1b[?996n", b"\x1b[?997;2n"),
    ]


def check_and_respond(master_fd: int, data: bytes, responses: list[tuple[bytes, bytes]]) -> list[str]:
    """Check for terminal queries in data and send responses. Returns list of response descriptions."""
    sent = []
    for pattern, response in responses:
        if pattern in data:
            os.write(master_fd, response)
            sent.append(f"  <- replied to {repr(pattern.decode('latin-1'))} with {repr(response.decode('latin-1'))}")
    return sent


def format_escape_sequence(data: bytes, offset: int) -> tuple[str, int]:
    """Parse and format an escape sequence starting at offset.
    Returns (formatted_string, bytes_consumed)."""
    if offset >= len(data) or data[offset] != 0x1B:
        return "", 0

    if offset + 1 >= len(data):
        return "ESC", 1

    next_byte = data[offset + 1]

    # CSI sequence: ESC [
    if next_byte == 0x5B:
        end = offset + 2
        while end < len(data):
            b = data[end]
            if 0x40 <= b <= 0x7E:
                seq = data[offset:end + 1]
                return seq.decode("latin-1"), end - offset + 1
            end += 1
        seq = data[offset:end]
        return seq.decode("latin-1") + "...", end - offset

    # OSC sequence: ESC ]
    if next_byte == 0x5D:
        end = offset + 2
        while end < len(data):
            b = data[end]
            if b == 0x07:
                seq = data[offset:end + 1]
                return seq.decode("latin-1"), end - offset + 1
            if b == 0x1B and end + 1 < len(data) and data[end + 1] == 0x5C:
                seq = data[offset:end + 2]
                return seq.decode("latin-1"), end - offset + 2
            end += 1
        seq = data[offset:min(end, offset + 80)]
        return seq.decode("latin-1") + "...", min(end, offset + 80) - offset

    # DCS sequence: ESC P
    if next_byte == 0x50:
        end = offset + 2
        while end < len(data):
            if data[end] == 0x1B and end + 1 < len(data) and data[end + 1] == 0x5C:
                length = end - offset + 2
                if length > 100:
                    return f"ESC P...({length} bytes)...ESC \\", length
                seq = data[offset:end + 2]
                return seq.decode("latin-1"), length
            end += 1
        return "ESC P...(unterminated)", end - offset

    # Two-byte escape
    seq = data[offset:offset + 2]
    return seq.decode("latin-1"), 2


def annotate_csi(seq_str: str) -> str:
    """Add a brief description to known CSI sequences."""
    # Match CSI params and final byte
    m = re.match(r'\x1b\[([?>=]?)([0-9;:]*)([$]?)([A-Za-z~])', seq_str)
    if not m:
        return ""
    prefix, params, dollar, final = m.groups()

    if prefix == '?' and final == 'h':
        modes = {"12": "blinking cursor", "1049": "alt screen", "25": "show cursor",
                 "1000": "mouse tracking", "1002": "mouse btn events", "1003": "mouse all events",
                 "1006": "SGR mouse", "2004": "bracketed paste", "2027": "grapheme cluster",
                 "2031": "mode 2031"}
        return f"  (DECSET {modes.get(params, params)})"
    if prefix == '?' and final == 'l':
        modes = {"12": "no blink cursor", "25": "hide cursor", "1049": "normal screen",
                 "2004": "no bracketed paste"}
        return f"  (DECRST {modes.get(params, params)})"
    if prefix == '' and final == 'm':
        return f"  (SGR {params})"
    if prefix == '' and final == 'H':
        return f"  (CUP {params or '1;1'})"
    if prefix == '' and final == 'J':
        return f"  (ED {params or '0'})"
    if prefix == '' and final == 'K':
        return f"  (EL {params or '0'})"
    return ""


def dump_readable(data: bytes, out_path: str):
    """Write a human-readable annotated dump."""
    with open(out_path, "w") as f:
        i = 0
        while i < len(data):
            b = data[i]

            # Escape sequences
            if b == 0x1B:
                seq_str, consumed = format_escape_sequence(data, i)
                if consumed > 0:
                    raw_hex = " ".join(f"{data[i+j]:02X}" for j in range(min(consumed, 20)))
                    if consumed > 20:
                        raw_hex += " ..."
                    annotation = annotate_csi(seq_str) if seq_str.startswith("\x1b[") else ""
                    f.write(f"[{i:06X}] {raw_hex}\n")
                    f.write(f"         -> {repr(seq_str)}{annotation}\n")
                    i += consumed
                    continue

            # Printable ASCII run
            if 0x20 <= b < 0x7F:
                run_start = i
                while i < len(data) and 0x20 <= data[i] < 0x7F and data[i] != 0x1B:
                    i += 1
                text = data[run_start:i].decode("ascii")
                if len(text) > 120:
                    f.write(f"[{run_start:06X}] TEXT({len(text)}): {repr(text[:80])}...\n")
                else:
                    f.write(f"[{run_start:06X}] TEXT: {repr(text)}\n")
                continue

            # UTF-8 multi-byte
            if b >= 0x80:
                if b < 0xC0:
                    f.write(f"[{i:06X}] {b:02X}  (continuation byte)\n")
                    i += 1
                    continue
                nbytes = 2 if b < 0xE0 else (3 if b < 0xF0 else 4)
                end = min(i + nbytes, len(data))
                raw = data[i:end]
                try:
                    ch = raw.decode("utf-8")
                    hex_str = " ".join(f"{x:02X}" for x in raw)
                    f.write(f"[{i:06X}] {hex_str}  U+{ord(ch):04X} {repr(ch)}\n")
                except UnicodeDecodeError:
                    hex_str = " ".join(f"{x:02X}" for x in raw)
                    f.write(f"[{i:06X}] {hex_str}  (invalid UTF-8)\n")
                i = end
                continue

            # Control characters
            names = {0x07: "BEL", 0x08: "BS", 0x0A: "LF", 0x0D: "CR", 0x0E: "SO", 0x0F: "SI"}
            f.write(f"[{i:06X}] {b:02X}  {names.get(b, f'C0 {b:#04x}')}\n")
            i += 1


def main():
    parser = argparse.ArgumentParser(description="Capture raw PTY output for debugging")
    parser.add_argument("command", nargs="*", default=["opencode"],
                        help="Command to run (default: opencode)")
    parser.add_argument("--duration", "-d", type=float, default=5.0,
                        help="Seconds to capture (default: 5)")
    parser.add_argument("--rows", type=int, default=40, help="Terminal rows (default: 40)")
    parser.add_argument("--cols", type=int, default=120, help="Terminal columns (default: 120)")
    parser.add_argument("--output", "-o", default="dev/pty_capture",
                        help="Output path prefix (default: dev/pty_capture)")
    args = parser.parse_args()

    bin_path = args.output + ".bin"
    txt_path = args.output + ".txt"

    print(f"Capturing PTY output from: {' '.join(args.command)}")
    print(f"Terminal size: {args.cols}x{args.rows}")
    print(f"Duration: {args.duration}s")

    master_fd, slave_fd = pty.openpty()
    winsize = struct.pack("HHHH", args.rows, args.cols, 0, 0)
    fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsize)

    env = os.environ.copy()
    env["TERM"] = "xterm-256color"

    responses = build_responses(args.rows, args.cols)

    pid = os.fork()
    if pid == 0:
        os.close(master_fd)
        os.setsid()
        fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)
        os.dup2(slave_fd, 0)
        os.dup2(slave_fd, 1)
        os.dup2(slave_fd, 2)
        if slave_fd > 2:
            os.close(slave_fd)
        os.execvpe(args.command[0], args.command, env)
        sys.exit(1)

    os.close(slave_fd)
    collected = bytearray()
    start_time = time.monotonic()
    deadline = start_time + args.duration

    try:
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            ready, _, _ = select.select([master_fd], [], [], min(remaining, 0.05))
            if ready:
                try:
                    chunk = os.read(master_fd, 65536)
                    if not chunk:
                        break
                    collected.extend(chunk)
                    # Auto-respond to queries
                    sent = check_and_respond(master_fd, chunk, responses)
                    for msg in sent:
                        print(msg)
                except OSError:
                    break
    finally:
        try:
            os.kill(pid, signal.SIGTERM)
            time.sleep(0.1)
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        os.close(master_fd)

    with open(bin_path, "wb") as f:
        f.write(collected)
    print(f"\nRaw output: {bin_path} ({len(collected)} bytes)")

    dump_readable(bytes(collected), txt_path)
    print(f"Annotated:  {txt_path}")


if __name__ == "__main__":
    main()
