#!/usr/bin/env python3
"""Pack a staged package tree into an opkg-installable .ipk.

macOS-safe alternative to the OpenWrt SDK ``ipkg-build``. The system ``tar``
on macOS is bsdtar/libarchive, which emits PAX extended headers (typeflag
``x`` / 0x78). The busybox ``tar`` used by opkg cannot parse those and fails
with ``get_header_tar: Unknown typeflag: 0x78`` -> ``Malformed package file``.

This packer writes every tar layer with Python's GNU format (no PAX), owner
root:root and deterministic timestamps, and places the control files at the
root of control.tar.gz (not under ./CONTROL/). The result installs cleanly
through LuCI and the opkg CLI.

Usage:
    scripts/pack-ipk.py STAGING_DIR OUTPUT_DIR

STAGING_DIR is the tree produced by scripts/stage-package.sh: a payload
(./etc, ./usr, ...) plus a CONTROL/ directory holding control, conffiles and
maintainer scripts. The package name and version are read from CONTROL/control.
"""

import io
import gzip
import os
import sys
import tarfile

EPOCH = 0


def _norm(ti):
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.mtime = EPOCH
    return ti


def _build_tar(members):
    """members: list of (arcname, abspath). GNU format => no PAX headers."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for arc, path in members:
            ti = tf.gettarinfo(name=path, arcname=arc)
            _norm(ti)
            if ti.isreg():
                with open(path, "rb") as fh:
                    tf.addfile(ti, fh)
            else:
                tf.addfile(ti)
    gz = io.BytesIO()
    with gzip.GzipFile(fileobj=gz, mode="wb", mtime=EPOCH) as g:
        g.write(raw.getvalue())
    return gz.getvalue()


def _payload_members(stage):
    members = []
    for root, dirs, files in os.walk(stage):
        dirs.sort()
        rel = os.path.relpath(root, stage)
        if rel == "CONTROL" or rel.startswith("CONTROL" + os.sep):
            continue
        if rel != ".":
            members.append(("./" + rel, root))
        for fn in sorted(files):
            full = os.path.join(root, fn)
            members.append(("./" + os.path.relpath(full, stage), full))
    members.sort(key=lambda m: m[0])
    return members


def _control_members(stage):
    cdir = os.path.join(stage, "CONTROL")
    members = [("./", cdir)]
    for fn in sorted(os.listdir(cdir)):
        members.append(("./" + fn, os.path.join(cdir, fn)))
    return members


def _read_field(control_path, key):
    with open(control_path) as fh:
        for line in fh:
            if line.startswith(key + ":"):
                return line.split(":", 1)[1].strip()
    raise SystemExit("missing %s in %s" % (key, control_path))


def main(argv):
    if len(argv) != 3:
        raise SystemExit("usage: pack-ipk.py STAGING_DIR OUTPUT_DIR")
    stage, outdir = argv[1], argv[2]
    control = os.path.join(stage, "CONTROL", "control")
    name = _read_field(control, "Package")
    version = _read_field(control, "Version")
    arch = _read_field(control, "Architecture")

    data_tar = _build_tar(_payload_members(stage))
    control_tar = _build_tar(_control_members(stage))

    os.makedirs(outdir, exist_ok=True)
    out = os.path.join(outdir, "%s_%s_%s.ipk" % (name, version, arch))

    parts = {
        "debian-binary": b"2.0\n",
        "data.tar.gz": data_tar,
        "control.tar.gz": control_tar,
    }
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for member in ("debian-binary", "data.tar.gz", "control.tar.gz"):
            payload = parts[member]
            ti = tarfile.TarInfo("./" + member)
            ti.size = len(payload)
            ti.mode = 0o644
            _norm(ti)
            tf.addfile(ti, io.BytesIO(payload))
    with gzip.GzipFile(out, "wb", mtime=EPOCH) as g:
        g.write(raw.getvalue())

    print(out)


if __name__ == "__main__":
    main(sys.argv)
