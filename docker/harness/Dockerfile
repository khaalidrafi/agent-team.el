# agent-team-harness — CI turn container with agent bodies PREINSTALLED.
# Owner order 2026-10-20 (#hq): "Use Docker containers with agents
# preinstalled. Don't install in CI. That's a waste of time. You'll have
# to make agent configs, too, and reuse them."
#
# Secrets are NEVER baked: provider keys are injected per run as env vars
# (OPENROUTER_API_KEY / ZAI_API_KEY / GROQ_API_KEY /
#  QODER_PERSONAL_ACCESS_TOKEN / CODEBUDDY_*) from repo secrets.

FROM debian:stable-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git curl ca-certificates bzip2 jq procps nodejs npm \
 && rm -rf /var/lib/apt/lists/*

# --- OpenCode body (preinstalled once, reused every turn) -------------------
# Installed under /usr/local/lib so the non-root run user can traverse it.
RUN export HOME=/usr/local/lib/opencode-home \
 && curl -fsSL https://opencode.ai/install | bash \
 && chmod -R a+rX /usr/local/lib/opencode-home \
 && ln -sf /usr/local/lib/opencode-home/.opencode/bin/opencode /usr/local/bin/opencode

# --- Goose body (direct tarball: the download_cli.sh installer opens
#     /dev/tty and dies on headless runners — demo/01 turn 2 evidence) ------
RUN mkdir -p /tmp/goose-dl \
 && curl -fsSL -o /tmp/goose-dl/goose.tar.bz2 \
      https://github.com/block/goose/releases/download/stable/goose-x86_64-unknown-linux-gnu.tar.bz2 \
 && tar -xjf /tmp/goose-dl/goose.tar.bz2 -C /tmp/goose-dl \
 && install -m 0755 /tmp/goose-dl/goose /usr/local/bin/goose \
 && rm -rf /tmp/goose-dl

# --- Qoder body (keys landed 2026-10-21: Owner PAT -> repo secret
#     QODER_PERSONAL_ACCESS_TOKEN; CLI auto-detects CI and uses the PAT,
#     no browser — Task 6 auth research). Install under /usr/local/lib so
#     the non-root run user can traverse it; binary path found at build
#     time and symlinked (installer's target dir is not documented). ------
RUN export HOME=/usr/local/lib/qoder-home \
 && curl -fsSL https://qoder.com/install | bash \
 && chmod -R a+rX /usr/local/lib/qoder-home \
 && QBIN=$(find /usr/local/lib/qoder-home -type f -name qoder | head -1) \
 && ln -sf "$QBIN" /usr/local/bin/qoder \
 && qoder --version || true

# --- CodeBuddy body (Owner 2026-10-21: CodeBuddy access keys are pro-only,
#     so this body rides a THIRD-PARTY backend instead — no CodeBuddy
#     account needed: CODEBUDDY_API_KEY=<provider key> +
#     CODEBUDDY_BASE_URL=<OpenAI-compatible endpoint> + --model
#     (Task 6 auth research). Default lane: ZAI glm-5.3-flash — zero new
#     spend; flip to OpenRouter when credits land. Headless needs -y in
#     -p mode for tool use.) -------------------------------------------
RUN npm install -g @tencent-ai/codebuddy-code \
 && codebuddy --version || true

# --- Non-root run user (matches the Actions runner uid 1001) ---------------
RUN useradd -m -u 1001 agent

# --- Baked agent configs (Owner: "make agent configs, too, and reuse them").
#     Keys are env-interpolated at run time; nothing secret is baked. -------
COPY opencode.json     /home/agent/.config/opencode/opencode.json
COPY goose-config.yaml /home/agent/.config/goose/config.yaml
RUN chown -R agent:agent /home/agent

ENV HOME=/home/agent \
    GOOSE_PROVIDER=openrouter \
    GOOSE_MODEL=nvidia/nemotron-3.5-lightning:free

STOPSIGNAL SIGTERM
