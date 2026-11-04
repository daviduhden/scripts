#!/usr/bin/env python3
"""Exercise delivery transactions only in temporary paths with mocked services.

See the LICENSE file at the top of the project tree for copyright and
license details.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from test_sync_website_filters import REPOSITORY_ROOT, extract_function


@unittest.skipUnless(
    sys.platform.startswith("linux"), "SecureBlue helper targets Linux"
)
class ArtiInstallTests(unittest.TestCase):
    def run_installer(
        self,
        root: Path,
        *,
        fail: bool = False,
        replace: bool = False,
        malformed: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        mocks = root / "mocks"
        mocks.mkdir(exist_ok=True)
        for name, body in {
            "systemd-analyze": "#!/bin/sh\nexit 0\n",
            "systemctl": """#!/bin/sh
case "$*" in
*is-active*|*is-enabled*) exit 1;;
*enable*--now*) [ "$FAIL_START" = 0 ] || exit 1;;
esac
exit 0
""",
            "curl": """#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then shift; target=$1; fi
    shift
done
if [ "$BAD_TOML" = 1 ]; then printf '[broken' >"$target"; else printf '[storage]\\n' >"$target"; fi
""",
            "arti": '#!/bin/sh\nprintf "arti 1.4.0\\n"\n',
        }.items():
            executable = mocks / name
            executable.write_text(body)
            executable.chmod(0o755)
        env = dict(
            os.environ,
            HOME=str(root),
            XDG_CONFIG_HOME=str(root / "config & # % $ space"),
            XDG_DATA_HOME=str(root / "data & # % $ space"),
            XDG_STATE_HOME=str(root / "state & # % $ space"),
            XDG_CACHE_HOME=str(root / "cache & # % $ space"),
            FAIL_START=str(int(fail)),
            BAD_TOML=str(int(malformed)),
        )
        env["PATH"] = str(mocks) + os.pathsep + os.environ["PATH"]
        args = ["bash", str(REPOSITORY_ROOT / "secureblue/install-arti-service.bash")]
        if replace:
            args.append("--replace-config")
        return subprocess.run(
            args, env=env, text=True, capture_output=True, check=False
        )

    def test_preserves_config_and_escapes_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "config & # % $ space/arti/arti.toml"
            config.parent.mkdir(parents=True)
            config.write_text("# retained\n[storage]\n")
            result = self.run_installer(root)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(config.read_text(), "# retained\n[storage]\n")
            unit = (root / "config & # % $ space/systemd/user/arti.service").read_text()
            self.assertIn('%% $$ space/arti/arti.toml" proxy', unit)
            self.assertNotIn("%h/", unit)

    def test_activation_failure_restores_both_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            base = root / "config & # % $ space"
            config = base / "arti/arti.toml"
            unit = base / "systemd/user/arti.service"
            config.parent.mkdir(parents=True)
            unit.parent.mkdir(parents=True)
            config.write_text("# original\n[storage]\n")
            unit.write_text("# original unit\n")
            result = self.run_installer(root, fail=True, replace=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(config.read_text(), "# original\n[storage]\n")
            self.assertEqual(unit.read_text(), "# original unit\n")
            self.assertEqual(list(base.rglob("*.new.*")), [])

    def test_malformed_download_does_not_replace_unit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            unit = root / "config & # % $ space/systemd/user/arti.service"
            unit.parent.mkdir(parents=True)
            unit.write_text("# original unit\n")
            result = self.run_installer(root, malformed=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(unit.read_text(), "# original unit\n")


class WebsiteTransactionTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("bash"), "bash is not installed")
    def test_term_exits_and_releases_owned_lock(self) -> None:
        script = (REPOSITORY_ROOT / "debian/sync-website.bash").read_text()
        functions = "\n\n".join(
            extract_function(script, name)
            for name in ("acquire_lock", "cleanup_lock", "rollback_publication")
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            commands = """
WWW_DIR=$1
ATOMIC_PREVIOUS=''
acquire_lock
trap cleanup_lock EXIT
trap 'exit 143' TERM
kill -TERM $$
touch "$2"
"""
            marker = root / "continued"
            result = subprocess.run(
                [
                    "bash",
                    "-eu",
                    "-c",
                    functions + commands,
                    "test",
                    str(root / "public"),
                    str(marker),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 143, result.stderr)
            self.assertFalse(marker.exists())
            self.assertFalse((root / ".public.sync.lock").exists())

    def test_post_update_steps_fails_when_chmod_fails(self) -> None:
        script = (REPOSITORY_ROOT / "debian/sync-website.bash").read_text()
        function = extract_function(script, "post_update_steps")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            commands = """
log() { :; }
warn() { :; }
error() { printf '%s\\n' "$*" >&2; }
chown() { :; }
find() { return 1; }
systemctl() { :; }
WWW_DIR=$1
OWNER_USER=unused
OWNER_GROUP=unused
SERVICE_NAME=unused
if post_update_steps; then exit 99; fi
"""
            result = subprocess.run(
                ["bash", "-eu", "-c", function + commands, "test", str(root)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("exit 99", result.stdout)

    @unittest.skipUnless(sys.platform.startswith("linux"), "Debian helper uses GNU mv")
    def test_atomic_publication_and_rollback(self) -> None:
        self._exercise_atomic("debian/sync-website.bash", "bash")

    def test_openbsd_atomic_publication_and_rollback(self) -> None:
        if shutil.which("ksh") is None:
            self.skipTest("ksh is not installed")
        self._exercise_atomic("openbsd/sync-website.ksh", "ksh")

    def _exercise_atomic(self, relative_script: str, shell: str) -> None:
        script = (REPOSITORY_ROOT / relative_script).read_text()
        names = (
            "filter_site_tree",
            "has_repo_content",
            "reject_source_symlinks",
            "copy_from_source",
            "check_atomic_target",
            "replace_public_link",
            "rollback_publication",
            "stage_from_source",
            "acquire_lock",
            "cleanup_lock",
        )
        functions = "\n\n".join(extract_function(script, name) for name in names)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            old = root / "old"
            source = root / "source"
            old.mkdir()
            source.mkdir()
            (old / "index.html").write_text("old")
            (source / "index.html").write_text("new")
            (source / "AGENTS.md").write_text("private")
            public = root / "public"
            public.symlink_to(old, target_is_directory=True)
            commands = """
log() { :; }
warn() { :; }
error() { printf '%s\\n' "$*" >&2; }
chown() { :; }
restart_web_service() { :; }
ATOMIC_DEPLOY=1
ATOMIC_PREVIOUS=''
ATOMIC_RELEASE=''
OWNER_USER=unused
OWNER_GROUP=unused
WWW_DIR=$1
acquire_lock
[ "$LOCKDIR" != "$WWW_DIR/.sync.lock" ]
if acquire_lock; then exit 10; fi
stage_from_source "$2"
[ "$(cat "$WWW_DIR/index.html")" = new ]
[ ! -e "$WWW_DIR/AGENTS.md" ]
rollback_publication
[ "$(cat "$WWW_DIR/index.html")" = old ]
cleanup_lock
[ ! -e "$LOCKDIR" ]
"""
            result = subprocess.run(
                [
                    shell,
                    "-eu",
                    "-c",
                    functions + commands,
                    "test",
                    str(public),
                    str(source),
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)


@unittest.skipUnless(
    sys.platform.startswith("linux"), "SecureBlue helper targets Linux"
)
class XerjPublicationTests(unittest.TestCase):
    def test_concurrent_updates_use_independent_destination_temporaries(self) -> None:
        import hashlib
        import io
        import tarfile

        script = (REPOSITORY_ROOT / "secureblue/update-xerj.bash").read_text()
        functions = "\n\n".join(
            extract_function(script, name) for name in ("error", "log", "install_xerj")
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixtures = root / "fixtures"
            fixtures.mkdir()
            asset = "xerj-1.0.0-x86_64-unknown-linux-musl.tar.gz"
            executable = b"#!/bin/sh\nexit 0\n"
            with tarfile.open(fixtures / asset, "w:gz") as archive:
                entry = tarfile.TarInfo(asset.removesuffix(".tar.gz") + "/xerj")
                entry.size = len(executable)
                archive.addfile(entry, io.BytesIO(executable))
            digest = hashlib.sha256((fixtures / asset).read_bytes()).hexdigest()
            (fixtures / (asset + ".sha256")).write_text(f"{digest}  {asset}\n")
            mocks = root / "mocks"
            mocks.mkdir()
            curl = mocks / "curl"
            curl.write_text("""#!/bin/sh
while [ "$#" -gt 0 ]; do
 case "$1" in
 https://*) url=$1;;
 -o) shift; target=$1;;
 esac
 shift
done
cp "$FIXTURES/${url##*/}" "$target"
""")
            curl.chmod(0o755)
            env = dict(
                os.environ,
                HOME=str(root),
                FIXTURES=str(fixtures),
                PERL_CMD=shutil.which("perl") or "perl",
            )
            env["PATH"] = str(mocks) + os.pathsep + os.environ["PATH"]
            commands = "\nVERSION=v1.0.0\nTMP_DIR=''\nBINARY_STAGE=''\ninstall_xerj\n"
            children = [
                subprocess.Popen(
                    ["bash", "-eu", "-c", functions + commands],
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                for _ in range(2)
            ]
            for child in children:
                stdout, stderr = child.communicate(timeout=20)
                self.assertEqual(child.returncode, 0, stdout + stderr)
            self.assertEqual((root / ".local/bin/xerj").read_bytes(), executable)
            self.assertEqual(list((root / ".local/bin").glob("xerj.new*")), [])


if __name__ == "__main__":
    unittest.main()
