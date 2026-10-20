#!/usr/bin/env bash
set +e
case "$SEAT" in
  principal-engineer)
    # OpenCode body + poolside: OpenCode cannot host the model
    # (absent from its models.dev catalog — demo/01 evidence) and
    # OpenRouter's free quota is exhausted. Attempt order:
    # 1. opencode (in case the catalog/defect is repaired);
    # 2. goose via OpenRouter poolside — SELF-HEALS the moment the
    #    Owner adds ~10 credits (harness/01 item 1/2); OpenRouter
    #    normalizes Goose's developer role server-side (demo/01
    #    evidence: qwen3.8-27b worked via OpenRouter, Groq didn't).
    if opencode run --print-logs --model "openrouter/poolside/laguna-s-2.1:free" "$BRIEF"; then
      echo "TURN_RESULT=opencode run OK"
    elif env GOOSE_PROVIDER=openai GOOSE_MODEL="poolside/laguna-s-2.1:free" \
         OPENAI_API_KEY="$OPENROUTER_API_KEY" \
         OPENAI_HOST="https://openrouter.ai/api/v1" \
         goose run --no-session -t "$BRIEF"; then
      echo "TURN_RESULT=goose run OK (lane: openrouter/poolside@goose — credits landed)"
    else
      echo "TURN_RESULT=BLOCKED (poolside dead on both bodies — Owner ruling: credits or brain swap, harness/01)"
    fi
    ;;
  quality-assurance-engineer|software-engineer|release-engineer)
    # LANE (mesh/01 repair, Lead, 2026-10-20 15:45Z): every lane on
    # the hired/fallback brains is dead — Groq rejects the
    # `developer` role Goose sends (400, req_01m5cqbghke9),
    # OpenRouter free-models-per-day exhausted (chain evidence:
    # "Add 10 credits"), OpenCode body headless-defective. The ONE
    # live lane with its own quota: ZAI glm-4.7-flash — same
    # OpenAI-compatible schema. Goose goes through its openai
    # provider with OPENAI_HOST pointed at ZAI. Fallback: the
    # rostered nemotron lane (in case OpenRouter quota resets).
    if env GOOSE_PROVIDER=openai GOOSE_MODEL=glm-4.7-flash \
         OPENAI_API_KEY="$ZAI_API_KEY" \
         OPENAI_HOST="https://api.z.ai" \
         OPENAI_BASE_PATH="/api/paas/v4/chat/completions" \
         goose run --no-session -t "$BRIEF"; then
      echo "TURN_RESULT=goose run OK (lane: zai/glm-4.7-flash@goose)"
    elif goose run --no-session -t "$BRIEF"; then
      echo "TURN_RESULT=goose run OK (lane: ${GOOSE_MODEL} — OpenRouter quota recovered)"
    else
      echo "TURN_RESULT=BLOCKED (zai lane + openrouter lane both failed — Lead escalation filed, harness/01)"
    fi
    ;;
esac
