#!/usr/bin/env python3
"""Plan by default; root-only, hash-checked, backed-up installation with --apply."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import time
import uuid

SOURCE = Path(__file__).resolve().parent
LEGACY = "/etc/cron.daily/coolify-auto-maintenance"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe(path):
    if any(p.is_symlink() for p in [path, *path.parents]):
        raise ValueError("symlink deployment path refused")


def atomic(path, data, mode):
    safe(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + "." + uuid.uuid4().hex)
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp, mode)
        os.replace(temp, path)
    finally:
        if temp.exists():
            temp.unlink()


def deploy(root=Path("/"), apply=False, expected=None):
    root = Path(root)
    legacy = root / LEGACY.lstrip("/")
    safe(legacy)
    original = legacy.read_bytes()
    old_stat = legacy.stat()
    if not stat.S_ISREG(old_stat.st_mode) or old_stat.st_uid != os.geteuid():
        raise ValueError("legacy file must be root-owned regular file")
    code = (SOURCE / "maintain.py").read_bytes()
    wrapper = (SOURCE / "coolify-auto-maintenance").read_bytes()
    version = "v1-" + digest(code)[:16]
    version_path = "/usr/local/libexec/hoghunter-maintenance/" + version + "/maintain.py"
    targets = [(root / version_path.lstrip("/"), code, 0o700),
               (root / "usr/local/sbin/hoghunter-maintain",
                ("#!/bin/sh\nexec /usr/bin/python3 " + version_path + ' "$@"\n').encode(), 0o700),
               (legacy, wrapper, 0o755)]
    for path, _, _ in targets:
        safe(path)
    result = {"apply": apply, "previous_sha256": digest(original), "previous_mode": oct(stat.S_IMODE(old_stat.st_mode)),
              "version": version, "targets": [{"path": "/" + str(p.relative_to(root)), "sha256": digest(d), "mode": oct(m)} for p, d, m in targets]}
    if not apply:
        return result
    if os.geteuid() != 0:
        raise ValueError("apply requires root")
    if expected != digest(original):
        raise ValueError("expected legacy hash does not match")
    backup = root / "var/backups/hoghunter-maintenance" / (str(int(time.time())) + "-" + uuid.uuid4().hex)
    safe(backup)
    backup.mkdir(parents=True, mode=0o700)
    os.chmod(backup, 0o700)
    atomic(backup / "coolify-auto-maintenance", original, 0o600)
    atomic(backup / "manifest.json", json.dumps(result).encode(), 0o600)
    # Recheck after backup, before installing either entry point.
    current = legacy.stat()
    if (current.st_ino, current.st_mtime_ns, current.st_size) != (old_stat.st_ino, old_stat.st_mtime_ns, old_stat.st_size) or digest(legacy.read_bytes()) != expected:
        raise ValueError("legacy file changed during deployment")
    for path, data, mode in targets:
        if path == legacy and digest(legacy.read_bytes()) != expected:
            raise ValueError("legacy file changed before cutover")
        atomic(path, data, mode)
        if digest(path.read_bytes()) != digest(data) or stat.S_IMODE(path.stat().st_mode) != mode or path.stat().st_uid != 0:
            raise ValueError("installed verification failed")
    audit = root / "var/log/hoghunter-maintenance-deploy.jsonl"
    safe(audit)
    fd = os.open(audit, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, (json.dumps(result) + "\n").encode())
        os.fsync(fd)
    finally:
        os.close(fd)
    result["backup"] = "/" + str(backup.relative_to(root))
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--expect-legacy-sha256")
    args = parser.parse_args()
    print(json.dumps(deploy(apply=args.apply, expected=args.expect_legacy_sha256)))
