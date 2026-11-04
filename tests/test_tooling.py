#!/usr/bin/env python3
"""Offline checks for validator immutability and installer error propagation.

See the LICENSE file at the top of the project tree for copyright
and license details.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
MOCK = r"""#!PYTHON
import pathlib
import sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if name == "ruff" and args == ["clean"]:
    raise SystemExit(0)
if name in ("perlcritic", "checkmake", "bmake"):
    raise SystemExit(0)
path = pathlib.Path(args[-1])
text = path.read_text()
drift = "# UNFORMATTED\n" in text
checking = "-l" in args or "--check" in args or "-ast" in args
if name == "ruff" and args[0] == "check":
    assert "--no-cache" in args
    raise SystemExit(0)
if name == "ruff":
    assert "--no-cache" in args
if checking:
    if drift and name == "shfmt":
        print(path)
    raise SystemExit(int(drift and name != "shfmt"))
path.write_text(text.replace("# UNFORMATTED\n", ""))
"""


class ToolingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tooling-tests-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.logs = self.base / "logs"
        self.logs.mkdir()
        for name in (
            "uname",
            "find",
            "sed",
            "grep",
            "mktemp",
            "rm",
            "sort",
            "wc",
            "tr",
            "awk",
            "dirname",
            "mkdir",
            "sh",
            "bash",
            "perl",
        ):
            command = shutil.which(name)
            if command:
                (self.bin / name).symlink_to(command)
        # Exercise the same optional-tool branches on every test host; the
        # OpenBSD-specific tool omissions are deliberately inapplicable.
        (self.bin / "uname").unlink()
        (self.bin / "uname").write_text("#!/bin/sh\nprintf '%s\\n' Linux\n")
        (self.bin / "uname").chmod(0o755)
        for name in (
            "shfmt",
            "perltidy",
            "mbake",
            "ruff",
            "perlcritic",
            "checkmake",
            "bmake",
        ):
            path = self.bin / name
            path.write_text(MOCK.replace("PYTHON", sys.executable, 1))
            path.chmod(0o755)
        (self.bin / "checkbashisms").write_text("#!/usr/bin/perl\nexit 0;\n")
        (self.bin / "checkbashisms").chmod(0o755)
        # A sh parser suffices for these fixtures, which contain no ksh code.
        (self.bin / "ksh").symlink_to(shutil.which("sh"))
        self.env = dict(
            os.environ,
            PATH=str(self.bin),
            TMPDIR=str(self.logs),
            PERL_LOCAL_LIB=str(self.base / "missing"),
        )

    def run_validator(self, kind, root, *flags):
        return subprocess.run(
            [
                "/bin/sh",
                str(REPO / f"tests-format/validate-{kind}.sh"),
                *flags,
                str(root),
            ],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_check_never_rewrites_and_format_is_explicit(self):
        for kind, name, content in (
            ("shell", "sample.sh", "#!/bin/sh\n# UNFORMATTED\nprintf '%s\\n' ok\n"),
            ("perl", "sample.pl", "# UNFORMATTED\nuse strict; use warnings;\n"),
            ("make", "Makefile", "# UNFORMATTED\nall:\n\t@true\n"),
            ("python", "sample.py", "# UNFORMATTED\nprint('ok')\n"),
        ):
            with self.subTest(kind=kind):
                root = self.base / kind
                root.mkdir()
                source = root / name
                source.write_text(content)
                cache = root / ".ruff_cache"
                cache.mkdir()
                (cache / "sentinel").write_text("keep")
                before = {
                    p.relative_to(root): p.read_bytes()
                    for p in root.rglob("*")
                    if p.is_file()
                }
                result = self.run_validator(kind, root, "--check")
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                after = {
                    p.relative_to(root): p.read_bytes()
                    for p in root.rglob("*")
                    if p.is_file()
                }
                self.assertEqual(before, after)
                result = self.run_validator(kind, root, "--format")
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertNotIn("UNFORMATTED", source.read_text())
                result = self.run_validator(kind, root)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_strict_rejects_missing_optional_tools(self):
        root = self.base / "source"
        root.mkdir()
        (root / "sample.sh").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "shfmt").unlink()
        self.assertEqual(self.run_validator("shell", root).returncode, 0)
        self.assertEqual(self.run_validator("shell", root, "--strict").returncode, 2)
        self.assertTrue(
            any("[SKIP] shfmt" in p.read_text() for p in self.logs.iterdir())
        )

    def test_predictable_legacy_symlinks_are_not_followed(self):
        for kind, name, content in (
            ("perl", "sample.pl", "# UNFORMATTED\nuse strict; use warnings;\n"),
            ("make", "Makefile", "# UNFORMATTED\nall:\n\t@true\n"),
        ):
            with self.subTest(kind=kind):
                root = self.base / f"legacy-{kind}"
                root.mkdir()
                (root / name).write_text(content)
                victim = self.base / f"victim-{kind}"
                victim.write_text("preserve")
                process = subprocess.Popen(
                    [
                        "/bin/sh",
                        "-c",
                        'printf "%s\\n" "$$"; read -r ready; exec /bin/sh "$1" --check "$2"',
                        "driver",
                        str(REPO / f"tests-format/validate-{kind}.sh"),
                        str(root),
                    ],
                    env=self.env,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                pid = process.stdout.readline().strip()
                for legacy in (
                    f"validate-{kind}-{pid}.log",
                    f"validate-{kind}-fails-{pid}.txt",
                    f"unformatted-{kind}-{pid}.txt",
                ):
                    (self.logs / legacy).symlink_to(victim)
                _, errors = process.communicate("\n", timeout=20)
                self.assertEqual(process.returncode, 2, errors)
                self.assertEqual(victim.read_text(), "preserve")

    def test_strict_rejects_unloadable_perl_modules(self):
        root = self.base / "perl-modules"
        root.mkdir()
        (root / "sample.pl").write_text("use ToolingFixture::DeliberatelyMissing;\n")
        self.assertEqual(self.run_validator("perl", root).returncode, 0)
        self.assertEqual(self.run_validator("perl", root, "--strict").returncode, 2)

    def test_make_execution_is_opt_in(self):
        root = self.base / "make-source"
        root.mkdir()
        (root / "Makefile").write_text("all:\n\t@true\n")
        marker = self.base / "make-executed"
        (self.bin / "bmake").write_text(f"#!/bin/sh\n: > '{marker}'\n")
        (self.bin / "bmake").chmod(0o755)
        self.assertEqual(self.run_validator("make", root).returncode, 0)
        self.assertFalse(marker.exists())
        self.assertEqual(
            self.run_validator("make", root, "--make-dry-run").returncode, 0
        )
        self.assertTrue(marker.exists())

    def test_install_accepts_destination_with_spaces(self):
        root = self.base / "installation"
        root.mkdir()
        (root / "Makefile").write_bytes((REPO / "Makefile").read_bytes())
        (root / "fixture.bash").write_text("#!/bin/bash\nexit 0\n")
        (self.bin / "install").symlink_to(shutil.which("install"))
        destination = root / "with spaces"
        result = subprocess.run(
            [
                shutil.which("make"),
                "install-debian",
                "DEBIAN_SCRIPTS=fixture.bash",
                f"BINDIR={destination}",
            ],
            cwd=root,
            env=self.env,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((destination / "fixture").is_file())

    def test_shell_install_restores_attribute_after_copy_failure(self):
        root = self.base / "shell-installation"
        root.mkdir()
        (root / "Makefile").write_bytes((REPO / "Makefile").read_bytes())
        destination = root / "bash config"
        destination.mkdir()
        marker = self.base / "chattr-calls"
        (self.bin / "chattr").write_text(
            f"#!/bin/sh\nprintf '%s\\n' \"$1\" >> '{marker}'\n"
        )
        (self.bin / "chattr").chmod(0o755)
        (self.bin / "install").write_text("#!/bin/sh\nexit 1\n")
        (self.bin / "install").chmod(0o755)
        result = subprocess.run(
            [
                shutil.which("make"),
                "install-shell-bash",
                "BASH_CONF_FILES=bad",
                f"BASH_CONF_DST_DIR={destination}",
            ],
            cwd=root,
            env=self.env,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text().splitlines(), ["-i", "+i"])

    def test_shell_scripts_do_not_embed_python(self):
        pattern = re.compile(r"python3?\s+(-c\b|-\s*<<|-\s*$)")
        for directory in ("debian", "openbsd", "secureblue", "shell", "tests-format"):
            for path in (REPO / directory).rglob("*"):
                if not path.is_file() or path.suffix not in {".sh", ".bash", ".ksh"}:
                    continue
                text = path.read_text(errors="replace")
                self.assertIsNone(
                    pattern.search(text),
                    f"embedded Python in {path.relative_to(REPO)}",
                )

    def test_install_loop_stops_at_first_failure(self):
        make = shutil.which("make")
        self.assertIsNotNone(make)
        root = self.base / "installation"
        root.mkdir()
        (root / "Makefile").write_bytes((REPO / "Makefile").read_bytes())
        marker = self.base / "late-install"
        installer = self.bin / "install"
        installer.write_text(
            '#!/bin/sh\ncase "$*" in\n*-d*) exit 0 ;;\n'
            f"*bad*) exit 1 ;;\n*) : > '{marker}' ;;\nesac\n"
        )
        installer.chmod(0o755)
        result = subprocess.run(
            [
                make,
                "install-debian",
                "DEBIAN_SCRIPTS=bad.bash later.bash",
                f"BINDIR={root / 'with spaces'}",
            ],
            cwd=root,
            env=self.env,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(
            marker.exists(), "a later success must not hide installation failure"
        )


if __name__ == "__main__":
    unittest.main()
