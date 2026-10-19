#!/usr/bin/env bash
# agent-team Codespaces setup — the cloud body for coding members.
# 2-core target: 90 wall-h/month on the student 180 core-h quota.
set -euo pipefail

echo "== system tools =="
sudo apt-get update -qq
sudo apt-get install -y -qq emacs-nox ripgrep fd-find curl jq python3-pip pipx
mkdir -p ~/.local/bin && ln -sf "$(command -v fdfind)" ~/.local/bin/fd || true

echo "== agent harnesses =="
npm install -g @larksuite/cli opencode-ai 2>/dev/null || npm install -g @larksuite/cli
pipx install aider-chat 2>/dev/null || pip install --user aider-chat
# Antigravity CLI: free 1,000 req/day Gemini serving, 1M ctx, no API key needed
curl -fsSL https://antigravity.google/docs/cli-install | bash || echo "antigravity install skipped"
# Pi parked until its config is ready (Owner decision)

echo "== lark skills =="
npx skills add larksuite/cli -y -g 2>/dev/null || true

echo "== self-check =="
echo "node:  $(node --version)"
echo "rg:    $(rg --version | head -1)"
echo "emacs: $(emacs --version | head -1)"
echo "aider: $(aider --version 2>/dev/null | head -1 || echo 'check pipx path')"
echo "opencode: $(opencode --version 2>/dev/null || echo missing)"
echo "lark-cli: $(lark-cli --version 2>/dev/null || echo 'configure auth: lark-cli config init --new')"

echo
echo "Next: Codespaces user secrets for OpenRouter/Groq keys;"
echo "then: lark-cli config init --new (device-code auth with the Owner)."
