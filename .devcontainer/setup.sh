#!/usr/bin/env bash
# agent-team Codespaces setup — cloud body for coding members.
# Bodies: ONLY what the Owner has installed (his provided list).
# 2-core target: 90 wall-h/month on the student 180 core-h quota.
set -euo pipefail

echo "== system tools =="
sudo apt-get update -qq
sudo apt-get install -y -qq emacs-nox ripgrep fd-find curl jq
mkdir -p ~/.local/bin && ln -sf "$(command -v fdfind)" ~/.local/bin/fd || true

echo "== harnesses (Owner-provided list only) =="
npm install -g @larksuite/cli opencode-ai 2>/dev/null || npm install -g @larksuite/cli
# Pi: parked until its config is ready (Owner decision) — not installed tonight
# Goose/Qoder/Cursor/Copilot: native to their environments, nothing to install

echo "== lark skills =="
npx skills add larksuite/cli -y -g 2>/dev/null || true

echo "== self-check =="
echo "node:  $(node --version)"
echo "rg:    $(rg --version | head -1)"
echo "emacs: $(emacs --version | head -1)"
echo "opencode: $(opencode --version 2>/dev/null || echo missing)"
echo "lark-cli: $(lark-cli --version 2>/dev/null || echo 'configure auth: lark-cli config init --new')"

echo
echo "Next: Codespaces user secrets for OpenRouter/Groq keys;"
echo "then: lark-cli config init --new (device-code auth with the Owner)."
