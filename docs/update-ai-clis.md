# AI CLI updater

Run `update-ai-clis` as the account that will run the agents. With no
arguments or with `all`, it processes the supported agents. Pass one or more
identifiers to restrict the operation to those agents and their dependencies.

```sh
update-ai-clis --help
update-ai-clis codex claude
update-ai-clis copilot-cli
update-ai-clis swival
update-ai-clis codex swival
```

The updater reports the agent, previous version, latest stable version in the
selected distribution channel, final version and result. Version checks run the
actual command, including after a package manager reports success. If more
than one installation is visible, review the reported paths and decide which
installation should own the command. Exit status 0 means the requested work
succeeded, 1 indicates an operational failure and 2 indicates invalid
arguments.

| Identifier | Command | Debian | SecureBlue | Windows |
| --- | --- | --- | --- | --- |
| `opencode` | `opencode` | OpenCode 2 native binary from the signed npm distribution | Homebrew `opencode` | OpenCode 2 release binary |
| `codex` | `codex` | Codex CLI release package | Homebrew cask | Codex CLI release package |
| `crush` | `crush` | Charm release package through APT | Official Charm tap | Charm release ZIP |
| `copilot-cli` | `copilot` | Standalone GitHub release | Homebrew cask | Standalone GitHub release ZIP |
| `claude` | `claude` | Anthropic stable APT channel | Homebrew stable cask | Anthropic native binary |
| `swival` | `swival` | Official Astral uv release and isolated PyPI tool | Homebrew core `uv` and isolated PyPI tool | Official Astral uv release and isolated PyPI tool |

Most of these distributions use native executables. Node.js, npm and Bun are needed
only for other distribution routes or workloads that explicitly use them.
Git enables repository features. GitHub CLI is separate from the Copilot CLI.
Claude Code on Linux requires Bash or Zsh. Git for Windows is optional for
Claude Code and provides Git Bash. Existing account and agent settings remain
in their current locations.

The Linux packages target amd64 and arm64, and the Windows builds target
x64 and ARM64. On Debian, Crush is also supported on armhf. The updater on
Linux checks the configured login shell and, if
needed, appends an idempotent PATH entry to its user startup file. Supported
shells include Bash, Zsh, Fish, sh/dash and ksh. On Windows, managed binaries
use the user PATH and are checked from a new PowerShell process with the
persistent machine and user PATH combined. The scripts preserve existing
shell configuration. Profiles or terminal applications that change PATH can
affect which executable is launched.

Swival uses the upstream `uv tool` distribution and a uv-managed Python
3.14 in its isolated environment. Swival 1.9.6 declares Python
`>=3.13,<3.15`. uv resolves its Python dependencies from PyPI. Debian's
system Python and SecureBlue's system image are outside this installation.
The official Swival Homebrew tap documents macOS only. SecureBlue uses
Homebrew core for uv and PyPI for Swival. The updater does not install
the optional `nono` sandbox or the optional MetaSKILLs runtime. An existing
Swival configuration, including the security settings, stays in place.
[Swival installation](https://swival.dev/pages/getting-started.html) ·
[Published package metadata](https://github.com/Swival/swival/blob/1.9.6/pyproject.toml) ·
[Optional nono sandbox](https://swival.dev/pages/nono.html)

The Swival installer targets amd64 and arm64 on Linux and x64 on Windows.
Native Windows ARM64 is excluded while required packages such as
`tiktoken` and `html-to-markdown` lack Windows ARM64 wheels. The updater
reports conflicting installations so you can manage them through their
original package channel. Linux publishes the selected command in
`~/.local/bin`; Debian also uses it for managed uv. Windows uses
`%LOCALAPPDATA%\Programs\Swival\bin` for its launchers. SecureBlue uses
the Homebrew path for uv. The updater checks the resolved commands from a
fresh session.
The Python interpreter stays private to uv's tool environment.
[tiktoken distributions](https://pypi.org/project/tiktoken/0.14.0/#files) ·
[html-to-markdown distributions](https://pypi.org/project/html-to-markdown/3.23.2/#files)

The updater selects stable Swival release metadata and checks the wheel
against its published SHA-256. It uses the official PyPI index for
dependencies and requires prebuilt wheels. It updates the managed uv and
Python runtimes when needed and leaves external package managers in charge
of their own installations. GitHub's release API is used for the managed
Astral archive on Debian and Windows.

An already current Swival release keeps its existing tool environment.
Compatible Python packages are resolved when the environment is first
installed or replaced for a Swival update.

Debian uses APT for TLS certificates and curl, jq for GitHub metadata,
OpenSSL for the npm registry signature, Cosign for Codex and Crush, and
Perl for bounded archive extraction. On SecureBlue, Homebrew manages
package dependencies, including libraries and tools such as ripgrep for
the OpenCode formula. On Windows, PowerShell and its bundled Windows/.NET
tools validate and unpack the publishers' native executables. Codex uses
Windows' `tar.exe` and includes its sandbox, code-mode host and ripgrep.

Release versions come from the relevant publishing channel. A current
Homebrew or stable-channel release can differ from a release announced on
GitHub. GitHub's public API can rate-limit unauthenticated requests. An
unavailable version or an executable outside the expected channel is
reported in the summary and accompanying diagnostics.

The platform guides cover prerequisites and paths. [Debian](../debian/README.md)
[SecureBlue](../secureblue/README.md) [Windows](../windows/README.md)

Upstream documentation

- [OpenCode](https://opencode.ai/docs/) and [OpenCode releases](https://github.com/anomalyco/opencode/releases)
- [OpenAI Codex CLI](https://github.com/openai/codex)
- [Charm Crush](https://github.com/charmbracelet/crush)
- [GitHub Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli)
- [Anthropic Claude Code](https://code.claude.com/docs/en/setup)
- [Swival](https://swival.dev/) and [Swival on PyPI](https://pypi.org/project/swival/)
