#!/usr/bin/env python3
"""Offline release-update regressions; no administrative entry point is run.

See the LICENSE file at the top of the project tree for copyright and
license details.
"""

import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def functions(path):
    """Load definitions while omitting the final administrative main call."""
    text = (ROOT / path).read_text()
    prefix, suffix = text.rsplit('\nmain "$@"', 1)
    if suffix.strip():
        raise AssertionError("Unexpected code after main")
    return prefix


@unittest.skipUnless(
    sys.platform.startswith("linux"), "Linux release updaters require GNU/Linux"
)
class ReleaseUpdates(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="release-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def archive(self, entries):
        path = self.root / "fixture.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            for name, data, kind in entries:
                info = tarfile.TarInfo(name)
                info.mode = 0o755
                info.type = kind
                info.size = len(data) if kind == tarfile.REGTYPE else 0
                info.linkname = "/etc/passwd" if kind == tarfile.SYMTYPE else ""
                archive.addfile(info, io.BytesIO(data) if info.size else None)
        return path

    def run_shell(self, path, body, **extra):
        env = os.environ.copy()
        env.update(
            TEST_ROOT=str(self.root),
            PERL_CMD=shutil.which("perl") or "perl",
            **extra,
        )
        return subprocess.run(
            ["bash", "-c", functions(path) + "\n" + body],
            env=env,
            check=False,
            text=True,
            capture_output=True,
            timeout=20,
        )

    def test_msedit_checks_digest_and_exact_entry(self):
        for kind in ("valid", "digest", "duplicate", "link"):
            with self.subTest(kind=kind):
                work = self.root / "work"
                work.mkdir(exist_ok=True)
                (work / "edit").unlink(missing_ok=True)
                binary = self.root / "bin" / "edit"
                binary.parent.mkdir(exist_ok=True)
                binary.write_bytes(b"previous")
                entries = [("edit", b"new", tarfile.REGTYPE)]
                if kind == "duplicate":
                    entries *= 2
                if kind == "link":
                    entries = [("edit", b"", tarfile.SYMTYPE)]
                archive = self.archive(entries)
                digest = hashlib.sha256(archive.read_bytes()).hexdigest()
                if kind == "digest":
                    digest = "0" * 64
                result = self.run_shell(
                    "debian/update-msedit.bash",
                    """
WORK_DIR="$TEST_ROOT/work"
INSTALL_DIR="$TEST_ROOT/bin"
net_curl() { cp -- "$FIXTURE" "${@: -1}"; }
run_root() { "$@"; }
install_msedit https://github.com/microsoft/edit/releases/download/v2.0.0/fixture "$DIGEST"
""",
                    FIXTURE=str(archive),
                    DIGEST="sha256:" + digest,
                )
                self.assertEqual(result.returncode == 0, kind == "valid", result.stderr)
                self.assertEqual(
                    binary.read_bytes(), b"new" if kind == "valid" else b"previous"
                )

    def test_btop_fallback_requires_exact_safe_source_tree(self):
        for kind in (
            "valid",
            "traversal",
            "duplicate",
            "link",
            "hardlink",
            "wrong-root",
        ):
            with self.subTest(kind=kind):
                entries = [("btop-1.0.0/Makefile", b"all:\n", tarfile.REGTYPE)]
                if kind == "traversal":
                    entries += [("btop-1.0.0/../../outside", b"bad", tarfile.REGTYPE)]
                elif kind == "duplicate":
                    entries *= 2
                elif kind == "link":
                    entries += [("btop-1.0.0/link", b"", tarfile.SYMTYPE)]
                elif kind == "hardlink":
                    entries += [("btop-1.0.0/link", b"", tarfile.LNKTYPE)]
                elif kind == "wrong-root":
                    entries = [("other/Makefile", b"wrong", tarfile.REGTYPE)]
                fixture = self.archive(entries)
                destination = self.root / ("source-" + kind)
                stale = destination / "btop-stale"
                stale.mkdir(parents=True)
                (stale / "Makefile").write_text("stale")
                result = self.run_shell(
                    "debian/update-btop.bash",
                    """
git() { return 1; }
curl() { cp -- "$FIXTURE" "${@: -1}"; }
fetch_source v1.0.0 "$DESTINATION"
""",
                    FIXTURE=str(fixture),
                    DESTINATION=str(destination),
                )
                self.assertEqual(result.returncode == 0, kind == "valid", result.stderr)
                if kind == "valid":
                    source = Path(result.stdout.strip())
                    self.assertNotEqual(source, stale)
                    self.assertEqual((source / "Makefile").read_bytes(), b"all:\n")
                else:
                    self.assertEqual(list(destination.glob("btop-source.*")), [])
                self.assertFalse((self.root / "outside").exists())

    def test_btop_preparation_failure_is_checked_in_conditional_context(self):
        fixture = self.archive([("btop-1.0.0/Makefile", b"safe", tarfile.REGTYPE)])
        for failure in ("download", "mktemp"):
            with self.subTest(failure=failure):
                destination = self.root / failure
                destination.mkdir()
                # A failed download must not select a previous archive.
                (destination / "btop.tar.gz").write_bytes(fixture.read_bytes())
                result = self.run_shell(
                    "debian/update-btop.bash",
                    """
cd "$TEST_ROOT"
git() { return 1; }
curl() {
    [[ $FAILURE != download ]] || return 1
    cp -- "$FIXTURE" "${@: -1}"
}
mktemp() { return 1; }
if fetch_source v1.0.0 "$DESTINATION"; then exit 99; fi
""",
                    FIXTURE=str(fixture),
                    DESTINATION=str(destination),
                    FAILURE=failure,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((self.root / "btop-1.0.0").exists())

    def test_rustup_native_installer_checks_digest_before_execution(self):
        installer = self.root / "rustup-fixture"
        installer.write_text("""#!/bin/sh
mkdir -p "$HOME/.cargo/bin"
printf '#!/bin/sh\\nexit 0\\n' >"$HOME/.cargo/bin/cargo"
chmod 700 "$HOME/.cargo/bin/cargo"
: >"$HOME/rustup-executed"
""")
        digest = hashlib.sha256(installer.read_bytes()).hexdigest()
        for valid in (False, True):
            with self.subTest(valid=valid):
                home = self.root / ("home-" + str(valid))
                home.mkdir()
                temporary = home / "tmp"
                temporary.mkdir()
                result = self.run_shell(
                    "secureblue/update-arti-oniux.bash",
                    """
HOME=$FAKE_HOME
export HOME TMPDIR="$HOME/tmp"
ensure_brew_path() { return 0; }
command() {
    if [[ ${1:-} == -v ]]; then
        case "${2:-}" in
        cargo) [[ -f $HOME/rustup-executed ]] || return 1 ;;
        rustc|brew|brew-proxy) return 1 ;;
        esac
    fi
    builtin command "$@"
}
uname() { printf 'x86_64\n'; }
curl() {
    printf '%s\n' "$*" >>"$HOME/downloads"
    if [[ $* == *rustup-init.sha256* ]]; then
        printf '%s  rustup-init\n' "$DIGEST" >"${@: -1}"
    else cp -- "$FIXTURE" "${@: -1}"; fi
}
RUSTUP_VERSION=1.29.3
ensure_rust
""",
                    FIXTURE=str(installer),
                    DIGEST=digest if valid else "0" * 64,
                    FAKE_HOME=str(home),
                )
                self.assertEqual(result.returncode == 0, valid, result.stderr)
                self.assertEqual((home / "rustup-executed").exists(), valid)
                self.assertIn(
                    "/rustup/archive/1.29.3/x86_64-unknown-linux-gnu/rustup-init",
                    (home / "downloads").read_text(),
                )
                self.assertEqual(list(temporary.iterdir()), [])

    def test_argon_validates_both_scripts_before_first_execution(self):
        script = self.root / "first.sh"
        script.write_text('#!/bin/sh\n: >"$TEST_ROOT/executed"\n')
        digest = hashlib.sha256(script.read_bytes()).hexdigest()
        result = self.run_shell(
            "debian/update-argon-one-v3.bash",
            """
EEPROM_SHA256=$DIGEST
CONTROL_SHA256=$(printf '%064d' 0)
ARGON_EEPROM_SCRIPT=$FIXTURE
ARGON_CONTROL_SCRIPT=$FIXTURE
ask_reboot() { :; }
run_update
""",
            DIGEST=digest,
            FIXTURE=str(script),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "executed").exists())

    def go_update(self, failure="", bad_digest=False):
        installation = self.root / "install"
        (installation / "go").mkdir(parents=True)
        (installation / "go" / "previous").write_text("keep")
        fixture = self.archive(
            [
                (
                    "go/bin/go",
                    b"#!/bin/sh\nprintf 'go version go1.99.1 linux/amd64\\n'\n",
                    tarfile.REGTYPE,
                )
            ]
        )
        digest = hashlib.sha256(fixture.read_bytes()).hexdigest()
        metadata = self.root / "release.json"
        metadata.write_text(
            json.dumps(
                [
                    {
                        "files": [
                            {
                                "filename": "go1.99.1.linux-amd64.tar.gz",
                                "sha256": "0" * 64 if bad_digest else digest,
                            }
                        ]
                    }
                ]
            )
        )
        result = self.run_shell(
            "debian/update-golang.bash",
            """
INSTALL_DIR="$TEST_ROOT/install"
GO_ROOT="$INSTALL_DIR/go"
get_latest_go_version() { printf 'go1.99.1'; }
detect_go_arch() { printf 'amd64'; }
ensure_go_path_in_etc_profile() { :; }
net_curl() {
    if [[ $* == *mode=json* ]]; then cp -- "$METADATA" "${@: -1}";
    else cp -- "$FIXTURE" "${@: -1}"; fi
}
mv() {
    if [[ $FAILURE == activate && ${3:-} == *'.go-install.'*/go ]]; then return 1; fi
    command mv "$@"
    if [[ $FAILURE == signal && ${3:-} == "$GO_ROOT" ]]; then kill -TERM "$$"; fi
}
run_golang_update
""",
            FIXTURE=str(fixture),
            METADATA=str(metadata),
            FAILURE=failure,
        )
        return result, installation

    def test_go_success_preserves_backup_and_cleans_transaction(self):
        result, installation = self.go_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((installation / "go/bin/go").is_file())
        self.assertEqual(len(list(installation.glob(".go-backup.*/go/previous"))), 1)
        self.assertFalse(list(installation.glob(".go-install.*")))
        self.assertFalse((installation / ".go-update.lock").exists())

    def test_go_activation_failure_restores_original(self):
        result, installation = self.go_update("activate")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((installation / "go/previous").read_text(), "keep")
        self.assertFalse((installation / ".go-update.lock").exists())

    def test_go_signal_during_activation_restores_original(self):
        result, installation = self.go_update("signal")
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertEqual((installation / "go/previous").read_text(), "keep")
        self.assertFalse((installation / ".go-update.lock").exists())

    def test_go_digest_failure_keeps_original(self):
        result, installation = self.go_update(bad_digest=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((installation / "go/previous").read_text(), "keep")

    def test_argon_local_reviewed_scripts_require_matching_digest(self):
        source = self.root / "reviewed.sh"
        source.write_text("#!/bin/bash\nexit 0\n")
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        for expected in (digest, "0" * 64):
            result = self.run_shell(
                "debian/update-argon-one-v3.bash",
                'download_remote_script unused "$TEST_ROOT/pending.sh" "$DIGEST" "$FIXTURE"',
                DIGEST=expected,
                FIXTURE=str(source),
            )
            self.assertEqual(result.returncode == 0, expected == digest, result.stderr)


if __name__ == "__main__":
    unittest.main()
