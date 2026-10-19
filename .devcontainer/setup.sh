#!/usr/bin/env bash
# agent-team Codespaces setup — the cloud body for coding members.
# Runs once per codespace creation. Student quota: 180 core-h/month,
# so this image deliberately targets a 2-core machine (90 wall-hours).
set -euo pipefail

echo "== system tools =="
sudo apt-get update -qq
sudo apt-get install -y -qq emacs-nox ripgrep fd-find curl jq
# fd is installed as fdfind on Debian; alias it
mkdir -p ~/.local/bin && ln -sf "$(command -v fdfind)" ~/.local/bin/fd || true

echo "== agent harnesses (npm) =="
npm install -g @larksuite/cli opencode-ai 2>/dev/null || npm install -g @larksuite/cli

echo "== pi (minimal agent, Lead-body candidate) =="
curl -fsSL https://pi.dev/install.sh | bash || echo "pi install skipped (check pi.dev)"

echo "== lark skills =="
npx skills add larksuite/cli -y -g 2>/dev/null || true

echo "== self-check =="
echo "node: $(node --version)"
echo "rg:   $(rg --version | head -1)"
echo "emacs: $(emacs --version | head -1)"
echo "lark-cli: $(lark-cli --version 2>/dev/null || echo 'configure auth: lark-cli config init --new')"

echo
echo "Next: copy repo secrets (OpenRouter/Groq keys) into Codespaces user secrets,"
echo "then: lark-cli config init --new  (device-code auth with the Owner)"
