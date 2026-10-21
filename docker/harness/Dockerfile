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
#     no browser — Task 6 auth research).
#     RUNTIME ROOT CAUSE (proof run 39467719908, first platform segment):
#     the installer's `qoder` launcher resolves the real CLI under ITS
#     HOME — at build (HOME=/usr/local/lib/qoder-home) the version check
#     passed, at segment runtime HOME=/home/agent it printed "Qoder CLI
#     is not installed". Fix: keep the install tree under a+rwx and run
#     the launcher with HOME pinned to the install dir (also done in
#     ci.yml's platform branch). Version check is FATAL now — a body that
#     cannot run must fail the build loudly, not hide behind || true.
#     PATH FIX (CI evidence 2026-10-21, runs 39470194454/39470807232): the
#     installer does NOT put the dispatcher on PATH at all — it lives at
#     $HOME/.qoder/entry/qoder and resolves the real CLI via
#     $HOME/.local/bin/qodercli. Symlink the entry into /usr/local/bin at
#     build; HOME stays pinned (build here, runtime in ci.yml) so the
#     dispatcher's $HOME-relative discovery works for uid 1001. ---
RUN export HOME=/usr/local/lib/qoder-home \
 && curl -fsSL https://qoder.com/install | bash \
 && chmod -R a+rwX /usr/local/lib/qoder-home \
 && ln -sf /usr/local/lib/qoder-home/.qoder/entry/qoder /usr/local/bin/qoder \
 && timeout 60 qoder --version

# --- CodeBuddy body (Owner law 2026-10-21 17:47Z: CodeBuddy is kept for
#     its BUILT-IN models only. For API-served brains there is no novelty
#     in any body — "any agent can ride APIs, no surprise" — so the model
#     brain is installed into the BODY THAT FITS the work instead. Baked
#     and DORMANT until a CodeBuddy account credential exists (access
#     keys are pro-only; CODEBUDDY_AUTH_TOKEN / CODEBUDDY_API_KEY envs
#     ready to wire the moment one lands). Headless needs -y in -p mode
#     for tool use.) ----------------------------------------------------
RUN npm install -g @tencent-ai/codebuddy-code \
 && timeout 60 codebuddy --version

# --- Non-root run user (matches the Actions runner uid 1001) ---------------
RUN useradd -m -u 1001 agent

# --- Baked agent configs (Owner: "make agent configs, too, and reuse them").
#     Keys are env-interpolated at run time; nothing secret is baked. -------
COPY docker/harness/opencode.json     /home/agent/.config/opencode/opencode.json
COPY docker/harness/goose-config.yaml /home/agent/.config/goose/config.yaml
# Global AGENTS.md = agent law, CONFIGURED into memory (Owner 2026-10-21
# 08:22Z "configure the agent to load global AGENTS.md"; 09:16Z "read docs
# for each agent for how they configure global AGENTS.md"). Verified against
# each agent's official docs on 2026-10-21:
#   OpenCode  ~/.config/opencode/AGENTS.md — "applied across all opencode
#             sessions" (opencode.ai/docs/rules); repo-root AGENTS.md also
#             rides instructions[] in opencode.json.
#   Goose     ~/.config/goose/.goosehints is the GLOBAL hints file (goose
#             config dir, ~/.config/goose/); repo-root AGENTS.md/.goosehints
#             are additionally read from CWD per session.
#   CodeBuddy ~/.codebuddy/CODEBUDDY.md is the USER-LEVEL memory file,
#             "takes effect in all projects" (CodeBuddy docs, .codebuddy
#             directory structure); repo-root AGENTS.md auto-loads when no
#             CODEBUDDY.md exists (documented backward compatibility).
#   Qoder     no global/user rules path documented — repo-root AGENTS.md is
#             auto-recognized ("copy your AGENTS.md to your project
#             directory", docs.qoder.com/user-guide/rules); nothing baked.
COPY AGENTS.md /home/agent/.config/opencode/AGENTS.md
COPY AGENTS.md /home/agent/.config/goose/.goosehints
COPY AGENTS.md /home/agent/.codebuddy/CODEBUDDY.md
RUN chown -R agent:agent /home/agent

ENV HOME=/home/agent \
    GOOSE_PROVIDER=openrouter \
    GOOSE_MODEL=nvidia/nemotron-3.5-lightning:free

STOPSIGNAL SIGTERM
