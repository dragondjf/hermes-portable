# hermes-portable

Self-contained, **offline-capable** Hermes Agent package — unpacks into a user
home directory (`~/`), needs **no root**, **no system directories**, and runs
with **zero network at runtime**.

> Hermes Agent is a personal AI agent (CLI + gateway + TUI + skills). See the
> upstream project for the agent itself. This repo packages it as a green /
> portable install.

## What this is

A tarball you drop into any Linux user dir and run. No `pip install`, no network,
no root. The whole agent — interpreter, virtualenv, dependencies, launcher — is
bundled and relocatable.

```
hermes-portable/
├── install.sh        # one-shot deploy config (no root, no network, idempotent)
├── hermes.sh         # launcher — sets HERMES_HOME + PATH, then runs the agent
├── runtime/python/   # self-contained CPython 3.11 (copied, not a symlink)
├── hermes-agent/     # venv (deps installed) + source
└── home/             # offline config.yaml + bundled uv binary
```

## Deploy on a clean machine

```bash
tar xzf hermes-portable.tar.gz -C ~/
cd ~/hermes-portable
bash install.sh          # rewrites pyvenv.cfg, writes offline config, fixes paths
bash hermes.sh version   # verify
bash hermes.sh chat      # use it (point it at your LLM endpoint)
```

`install.sh` does the one-time configuration and needs no arguments. After that,
`./hermes.sh <subcommand>` is all you need.

## Rebuild from a newer Hermes checkout

`build_portable.sh` regenerates the package from `~/.hermes/hermes-agent`
(and the uv-managed CPython). Run it, then re-archive:

```bash
bash build_portable.sh
tar czf hermes-portable.tar.gz hermes-portable
```

## How it stays offline

- `security.allow_lazy_installs: false` and `update.check_on_startup: false`
  in `home/config.yaml` — optional backends and the updater never hit PyPI.
- The `uv` binary is bundled under `home/bin/uv` so the runtime repair path
  never downloads.
- The Python interpreter is copied (`venv --copies`) and bundled, so the package
  does not depend on uv's shared python directory or any system interpreter.

## Requirements

- Linux, x86_64, **glibc ≥ 2.39** (the build machine's version; glibc is
  forward-compatible only — an older target must be built on an older builder).
- Your LLM endpoint must be reachable from the machine (the agent needs a model;
  that network path is inherent and expected).

## Scope notes

- Core agent, `kanban`, chat, and gateway run fully offline (verified: SQLite
  task persistence works with no network).
- Optional integrations that are lazy extras (Slack / Matrix / Bedrock / voice /
  etc.) are not preinstalled and will report unavailable offline — that is by
  design, not a defect.
