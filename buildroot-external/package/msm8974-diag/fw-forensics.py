#!/usr/bin/env python3
"""Snapshot the firmware-owned SRAM regions that survive a warm reset.

The resets under investigation produce no kernel output whatsoever, and the
PMIC only ever reports PS_HOLD - i.e. *something on the SoC asked for a warm
reset* rather than a rail collapsing. The obvious candidates (RPM firmware, TZ)
do not log to Linux, but they do write into SRAM that a warm reset does not
clear:

  RPM MSG RAM  0xfc428000 (16 KiB)  the RPM's mailbox and its own log buffer
  IMEM         0xfe805000 ( 4 KiB)  restart reason / boot cookies written by
                                    SBL, TZ and the download-mode handlers

So dump both at every boot, before anything else has a chance to overwrite
them, and keep the dumps. Rather than rely on the downstream rpm_log header
offsets (which this kernel does not describe), extract printable strings and
keep the raw bytes alongside, so the dump stays useful even if the layout guess
is wrong.

Read-only: this only ever mmaps PROT_READ.
"""
import mmap
import os
import re
import sys

REGIONS = [
    ("rpm-msg-ram", 0xfc428000, 0x4000),
    ("imem", 0xfe805000, 0x1000),
]
DIAG = os.environ.get("DIAG_DIR", "/var/log/msm8974-diag")
MIN_STR = 6


def read_phys(base, size):
    page = base & ~0xfff
    off = base - page
    with open("/dev/mem", "rb") as f:
        m = mmap.mmap(f.fileno(), off + size, mmap.MAP_SHARED,
                      mmap.PROT_READ, offset=page)
        try:
            return m[off:off + size]
        finally:
            m.close()


def main():
    tag = sys.argv[1] if len(sys.argv) > 1 else "boot"
    os.makedirs(DIAG, exist_ok=True)
    out = os.path.join(DIAG, "fw-forensics-%s.txt" % tag)
    with open(out, "w") as rep:
        def emit(line):
            rep.write(line + "\n")
            print(line)

        emit("# firmware SRAM snapshot, kernel %s, uptime %ss"
             % (os.uname().release, open("/proc/uptime").read().split()[0]))
        for name, base, size in REGIONS:
            try:
                data = read_phys(base, size)
            except Exception as exc:                       # noqa: BLE001
                emit("\n## %s @ 0x%08x: unreadable (%s)" % (name, base, exc))
                continue
            raw = os.path.join(DIAG, "fw-%s-%s.bin" % (name, tag))
            with open(raw, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            nz = sum(1 for b in data if b)
            emit("\n## %s @ 0x%08x  %d bytes, %d non-zero -> %s"
                 % (name, base, size, nz, raw))
            for m in re.finditer(rb"[\x20-\x7e]{%d,}" % MIN_STR, data):
                emit("  +0x%04x  %s" % (m.start(), m.group().decode("ascii", "replace")))
        rep.flush()
        os.fsync(rep.fileno())
    print("saved %s" % out)


if __name__ == "__main__":
    main()
