# Configure agents with xerj

`update-xerj` installs or updates the xerj executable and registers its stdio
MCP server with supported installed clients. Use `update-ai-clis` to install
or update the clients themselves.

```sh
update-xerj
update-xerj all
update-xerj codex claude
update-xerj swival
update-xerj codex swival
update-xerj copilot-cli --url https://search.example.org
update-xerj --binary-only
update-xerj --binary-only --verify-attestation
update-xerj --help
```

All three platforms support `--verify-attestation`. It requires an authenticated
GitHub CLI with `gh release verify-asset` and verifies the selected archive
before installation. The updater keeps no backup of the previous executable.
Debian uses APT, SecureBlue renames the staged executable into place, and
Windows replaces the executable without requesting a backup file.

An empty selection and `all` have the same behavior. Both skip missing clients.
An explicitly selected client must be installed. `--binary-only` skips all
client configuration. Exit status 0 means success, 1 means an operational
failure and 2 means invalid arguments. `--version TAG` pins the xerj release.
`--url URL`
sets the node's Elasticsearch-compatible endpoint. Without it, the updater
uses `XERJ_URL` or `http://127.0.0.1:9200`. The endpoint must be HTTP or HTTPS
with a host and optional port and path. Keep credentials out of the URL.
The client runs the
verified local xerj binary by absolute path and passes the endpoint to
`xerj mcp`. Start the authenticated node separately and restart any open
client after changing its registration. [xerj CLI reference](https://xerj.org/docs/cli#mcp)

xerj supplies tools for search and indexing over MCP. Its optional facts
model is used by the node for answering questions against indexed content.
The endpoint serves Elasticsearch-compatible requests and has no documented
OpenAI Responses, Chat Completions or Anthropic Messages inference API.
Consequently, adding, renaming or removing models at an agent's inference
provider is outside this integration. The updater leaves the agent's model
catalog, selected model, provider credentials and other servers in place.
[xerj CLI reference](https://xerj.org/docs/cli) · [XERJ-Query](https://xerj.org/xerj-query-1)

## Compatibility

**Partial** means stdio MCP and a selectable search endpoint are supported
while inference provider and model management are unavailable. **Full**
would also require a compatible inference API. **Unavailable** means the
client/version lacks a usable registration method. **Unverified** means a
native end-to-end check is still pending.

| Client | Debian | SecureBlue | Windows | User registration | Inference configuration available in the client |
| --- | --- | --- | --- | --- | --- |
| OpenCode | Partial | Partial | Partial | `~/.config/opencode/opencode.json` or the XDG equivalent. V2 uses `mcp.servers.xerj`, V1 uses `mcp.xerj`. | `providers` supports custom endpoints, credentials by environment variable and model definitions. [OpenCode providers](https://opencode.ai/docs/providers/) |
| Codex CLI | Partial | Partial | Partial | Native `codex mcp` command, `${CODEX_HOME:-~/.codex}/config.toml`, `mcp_servers.xerj` | `model_provider`, `model` and `model_providers` select a Responses-compatible gateway and authentication. [Codex gateway](https://learn.chatgpt.com/docs/enterprise/gateway-compatibility) |
| Crush | Partial | Partial | Partial | Managed stdio block in `~/.config/crush/crushrc` or the XDG equivalent. `CRUSH_GLOBAL_CONFIG` selects the directory. | `provider add` and `model add` configure compatible API protocols, endpoint, credentials and models. [Crush configuration](https://github.com/charmbracelet/crush/blob/main/docs/config/README.md) |
| GitHub Copilot CLI | Partial | Partial | Partial | JSON in `${COPILOT_HOME:-~/.copilot}/mcp-config.json`, `mcpServers.xerj` | BYOK providers and models in `providers.json` or `COPILOT_PROVIDER_*` and `COPILOT_MODEL`. [Copilot providers](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-llm-models) |
| Claude Code | Partial | Partial | Partial | `~/.claude.json` or `$CLAUDE_CONFIG_DIR/.claude.json`, `mcpServers.xerj`. [Claude directories](https://code.claude.com/docs/en/claude-directory) | Anthropic-compatible gateways use `ANTHROPIC_BASE_URL`, gateway credentials and model settings. [Claude gateway](https://code.claude.com/docs/en/llm-gateway) |
| Swival | Partial | Partial | Partial | `${XDG_CONFIG_HOME:-~/.config}/swival/config.toml`, `[mcp_servers.xerj]` with the verified local command and endpoint as arguments. | The generic provider accepts an OpenAI-compatible Chat Completions endpoint and an explicit model. Its optional key can come from `OPENAI_API_KEY`. [Swival providers](https://swival.dev/pages/providers.html#generic-openai-compatible) |

On Windows, `~` refers to the user's profile. OpenCode and Crush use their
XDG config root when applicable, normally `~/.config`. User registration
keeps project configuration and managed policy intact. A project or
organization can override or restrict the effective server. Strict JSON
edits require an unambiguous object. Merge JSONC and conflicting
user-managed `xerj` entries manually. If an OpenCode environment override
changes the effective config, register xerj in the intended configuration
yourself. [OpenCode scopes](https://opencode.ai/docs/config/) ·
[Codex MCP](https://learn.chatgpt.com/docs/extend/mcp) ·
[Copilot MCP](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers) ·
[Claude MCP scopes](https://code.claude.com/docs/en/mcp)

For an existing Codex registration, change the endpoint in the user TOML
table. The native inspection command omits some supported settings, and
the native add command replaces the table. The updater uses a targeted
JSON merge for Claude because that client's native command creates state
backups. [Claude backup behavior](https://code.claude.com/docs/en/claude-directory)

xerj can discover its local `admin.key` for loopback connections. For a
remote node, provide `XERJ_AUTH` in the MCP process environment through a
supported client mechanism. Use HTTPS for remote authenticated connections.
The updater stores the endpoint and invocation only. Codex allows forwarding
the variable through `env_vars = ["XERJ_AUTH"]` in the server table. Add that
name-only setting manually when Codex needs it. Keep
credential values outside the file and command line. [xerj authentication](https://xerj.org/docs/cli#mcp) ·
[Codex stdio options](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)

Crush registration requires version 0.88.0 or later with `crushrc` support.
Existing conflicting legacy `crush.json` registrations need manual editing.
[Crush configuration](https://github.com/charmbracelet/crush/blob/main/docs/config/README.md)

Swival gives a project-level `xerj` table precedence over the global entry.
TOML wins over an MCP JSON definition with the same name, and `--no-mcp`
disables all MCP connections. The updater validates the Swival TOML with
the installed client and preserves conflicting user-managed definitions.
It appends a marked table on first registration. Keep that managed table
at the end of the file for automatic endpoint updates. Edit conflicts
manually if the table was moved or extended.
Existing model settings, provider endpoints, context limits and sandbox
policy are kept. Swival profiles can also set generation parameters such as
`temperature`, `top_p` and `max_output_tokens`. Swival needs an explicit
model for its generic inference provider. It can derive the context window
from model metadata when the
chosen inference server advertises it. XERJ provides search tools through
stdio MCP. For a remote authenticated XERJ node, make `XERJ_AUTH` available
to the Swival process. The registration contains the command and endpoint.
[Swival configuration precedence](https://swival.dev/pages/customization.html) ·
[Swival MCP](https://swival.dev/pages/mcp.html) ·
[Swival providers](https://swival.dev/pages/providers.html)

## Validation

Repository tests use disposable configuration directories and fake agents.
They cover first-time and repeated registration, endpoint changes, selected
and missing clients, preservation of unrelated settings, invalid input and
failed publication. The native commands and resulting user-scope schemas
were also checked on Linux for OpenCode V2, Codex, Copilot CLI and Claude Code.
The Crush block was checked against Charm's documented Bash configuration.
The Swival fixtures check an initial registration, a changed endpoint,
repeated runs and rejection of invalid or conflicting TOML. They exercise
staged publication with a substitute for the Swival validator.

| Platform | Registration tests | Native end-to-end connection |
| --- | --- | --- |
| Debian | Shared POSIX regression suite and staged launcher | Unverified |
| SecureBlue | Shared POSIX regression suite, staged launcher and isolated Linux configuration probes | Unverified |
| Windows | Portable PowerShell regression suite | Unverified on Windows |

See each platform guide for installation details. [Debian](../debian/README.md) ·
[SecureBlue](../secureblue/README.md) · [Windows](../windows/README.md)
