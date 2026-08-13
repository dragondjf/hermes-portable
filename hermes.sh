#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HERMES_HOME="$DIR/home"
export PATH="$DIR/home/bin:$DIR/hermes-agent/venv/bin:$PATH"
exec "$DIR/hermes-agent/venv/bin/python" -m hermes_cli.main "$@"
