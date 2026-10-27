"""Exercise website staging filters against disposable filesystem trees."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
INTERNAL_PATHS = (
    "README.md",
    "CODE_OF_CONDUCT.md",
    "CODEOFCONDUCT.md",
    "CONTRIBUTING.md",
    "AGENTS.md",
    "CLAUDE.md",
    "GEMINI.md",
    "copilot-instructions.md",
    ".git/config",
    ".github/workflows/archive.yml",
    ".agents/skills/example.md",
    ".claude/settings.json",
    ".codex/settings.json",
    ".gitignore",
    ".gitattributes",
    ".gitmodules",
    ".editorconfig",
    ".htmltest.yml",
    ".perlcriticrc",
    ".stylelintrc.json",
    "dprint.json",
    "docs/ARCHITECTURE.md",
    "t/check.t",
    "tests/check.py",
    "tmp/cache-entry",
    "tmp_archive/old.tar",
    ".cache/cache-entry",
    "nested/AGENTS.md",
    "scripts/openbsd-tools.txt",
    "scripts/validate-agent-knowledge.py",
    "editor.swp",
    "backup~",
)
PUBLIC_PATHS = (
    "index.html",
    "styles.css",
    "CNAME",
    "robots.txt",
    "sitemap.xml",
    ".well-known/security.txt",
    "articles/readme.md",
    "data/articles.json",
    "feeds/site.xml",
    "images/logo.svg",
    "scripts/linked-tool.pl",
    "templates/reference.html",
    "files/download.img",
)
SYNC_IMPLEMENTATIONS = (
    ("debian/sync-website.bash", "bash"),
    ("openbsd/sync-website.ksh", "ksh"),
)


def extract_function(script_text: str, name: str) -> str:
    """Read one top-level function without sourcing the deployment script."""
    lines = script_text.splitlines()
    start = next(
        index for index, line in enumerate(lines) if line.startswith(f"{name}() {{")
    )
    end = next(index for index in range(start + 1, len(lines)) if lines[index] == "}")
    return "\n".join(lines[start : end + 1])


class WebsiteSyncFilterTests(unittest.TestCase):
    def test_debian_filter_and_staging_paths(self) -> None:
        self._exercise_implementation(*SYNC_IMPLEMENTATIONS[0])

    def test_openbsd_filter_and_staging_paths(self) -> None:
        shell_name = SYNC_IMPLEMENTATIONS[1][1]
        shell = shutil.which(shell_name)
        if shell is None:
            self.skipTest(f"{shell_name} is not installed")
        self._exercise_implementation(*SYNC_IMPLEMENTATIONS[1])

    def _exercise_implementation(self, relative_script: str, shell_name: str) -> None:
        shell = shutil.which(shell_name)
        if shell is None:
            self.fail(f"{shell_name} is required for {relative_script}")
        script = REPOSITORY_ROOT / relative_script
        source_text = script.read_text(encoding="utf-8")
        functions = "\n\n".join(
            extract_function(source_text, name)
            for name in ("filter_site_tree", "has_repo_content", "stage_from_source")
        )
        for transfer_mode in ("rsync", "copy"):
            if transfer_mode == "rsync" and shutil.which("rsync") is None:
                continue
            for destination_state in ("initial", "update"):
                with self.subTest(
                    script=relative_script,
                    mode=transfer_mode,
                    destination=destination_state,
                ):
                    self._stage_fixture(
                        shell,
                        functions,
                        transfer_mode,
                        destination_state,
                    )

    def _stage_fixture(
        self,
        shell: str,
        functions: str,
        transfer_mode: str,
        destination_state: str,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="website-sync-test-") as temporary:
            root = Path(temporary)
            source = root / "source"
            destination = root / "public"
            source.mkdir()
            destination.mkdir()
            external_target = root / "external-target"
            external_target.write_text("must not be followed", encoding="utf-8")

            for relative_path in (*INTERNAL_PATHS, *PUBLIC_PATHS):
                target = source / relative_path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("fixture", encoding="utf-8")
            nested_repository_link = source / "nested" / ".git"
            nested_repository_link.parent.mkdir(parents=True, exist_ok=True)
            nested_repository_link.symlink_to(external_target)

            if destination_state == "update":
                for relative_path in (
                    "README.md",
                    ".git/config",
                    ".github/old-workflow.yml",
                    ".agents/old-instructions.md",
                    "docs/old-guide.md",
                    "stale-page.html",
                ):
                    target = destination / relative_path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text("stale", encoding="utf-8")
                old_repository_link = destination / "nested" / ".git"
                old_repository_link.parent.mkdir(parents=True, exist_ok=True)
                old_repository_link.symlink_to(external_target)

            lock = destination / ".sync.lock"
            lock.mkdir()
            (lock / "pid").write_text("active", encoding="utf-8")

            command = (
                f"SRC={str(source)!r}\n"
                f"WWW_DIR={str(destination)!r}\n"
                "warn() { :; }\n"
                f"{functions}\n"
                'stage_from_source "$SRC"\n'
            )
            environment = os.environ.copy()
            if transfer_mode == "copy":
                isolated_path = root / "path"
                isolated_path.mkdir()
                for utility in ("find", "rm", "cp"):
                    (isolated_path / utility).symlink_to(shutil.which(utility))
                environment["PATH"] = str(isolated_path)

            result = subprocess.run(
                [shell, "-c", command],
                check=False,
                capture_output=True,
                env=environment,
                text=True,
                timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            published = {
                path.relative_to(destination).as_posix()
                for path in destination.rglob("*")
            }
            leaked = [
                path
                for path in INTERNAL_PATHS
                if path in published
                or any(item.startswith(f"{path.rstrip('/')}/") for item in published)
            ]
            missing = [path for path in PUBLIC_PATHS if path not in published]
            self.assertEqual(leaked, [])
            self.assertEqual(missing, [])
            self.assertIn(".sync.lock/pid", published)
            if destination_state == "update":
                self.assertNotIn("stale-page.html", published)
            self.assertTrue(external_target.exists())


if __name__ == "__main__":
    unittest.main()
