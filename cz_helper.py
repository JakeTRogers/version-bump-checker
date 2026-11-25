"""Commitizen queries that the `cz` CLI doesn't expose.

check.sh runs this inside a checkout of the repository under test with
`uvx --from commitizen==<version> python cz_helper.py <command> ...`.
Only `commitizen.config.read_cfg` and `commitizen.version_schemes.get_version_scheme`
are used, so the dependency on Commitizen's Python API stays small.

Commands:
  describe                      print `config=<path>` and `provider=<name>`
  compare BASE HEAD [EXPECTED]  print `unchanged`, `decreased`, `too-small` (HEAD's
                                version core is below EXPECTED's), `finalization`
                                (HEAD is prerelease BASE's version core) or `increased`
  consistency VERSION           print each version_files entry that lacks VERSION
"""

from __future__ import annotations

import glob
import os
import re
import sys

from commitizen.config import read_cfg
from commitizen.version_schemes import get_version_scheme


def describe(settings: dict, path: object) -> None:
    print(f"config={path or ''}")
    print(f"provider={settings.get('version_provider') or 'commitizen'}")


def _padded(release: tuple[int, ...], length: int) -> tuple[int, ...]:
    return release + (0,) * (length - len(release))


def compare(settings: dict, base: str, head: str, expected: str | None) -> None:
    """Print how HEAD relates to BASE; `verdict` in check.sh decides which relations pass."""
    scheme = get_version_scheme(settings)
    base_v, head_v = scheme(base), scheme(head)
    if head_v == base_v:
        print("unchanged")
    elif head_v < base_v:
        print("decreased")
    elif expected and _core_below(head_v.release, scheme(expected).release):
        print("too-small")
    elif base_v.is_prerelease and head_v == scheme(base_v.base_version):
        print("finalization")
    else:
        print("increased")


def _core_below(core: tuple[int, ...], target: tuple[int, ...]) -> bool:
    # Only the version cores count: 1.3.0-rc1 meets an expected 1.3.0.
    length = max(len(core), len(target))
    return _padded(core, length) < _padded(target, length)


def consistency(settings: dict, version: str) -> int:
    """Mirror `cz bump --check-consistency` without running a bump (and its hooks)."""
    encoding = settings.get("encoding") or "utf-8"
    missing = 0
    for entry in settings.get("version_files") or []:
        drive, tail = os.path.splitdrive(entry)
        path, _, regex = tail.partition(":")
        pattern = re.compile(regex or re.escape(version))
        files = sorted(glob.glob(drive + path))
        if not files:
            print(f"{entry} (no matching file)")
            missing += 1
            continue
        for file in files:
            with open(file, encoding=encoding) as handle:
                if not any(pattern.search(line) and version in line for line in handle):
                    print(f"{file} (version {version} not found)")
                    missing += 1
    return 1 if missing else 0


def main(argv: list[str]) -> int:
    config = read_cfg()
    settings = config.settings
    command, args = (argv[0], argv[1:]) if argv else ("", [])
    if command == "describe" and not args:
        describe(settings, config.path)
        return 0
    if command == "compare" and len(args) in (2, 3):
        compare(settings, args[0], args[1], args[2] if len(args) == 3 else None)
        return 0
    if command == "consistency" and len(args) == 1:
        return consistency(settings, args[0])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
