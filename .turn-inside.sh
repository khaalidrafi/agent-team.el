#!/usr/bin/env bash
set +e
case "$SEAT" in
  principal-engineer)
    opencode run --print-logs --model "openrouter/poolside/laguna-s-2.1:free" "$BRIEF" \
      && echo "TURN_RESULT=opencode run OK" \
      || echo "TURN_RESULT=BLOCKED (opencode run failed — Release Engineer's next turn repairs the harness)"
    ;;
  quality-assurance-engineer)
    opencode run --print-logs --model "zai/glm-4.7-flash" "$BRIEF" \
      && echo "TURN_RESULT=opencode run OK" \
      || echo "TURN_RESULT=BLOCKED (opencode run failed — Release Engineer's next turn repairs the harness)"
    ;;
  software-engineer|release-engineer)
    goose run --no-session -t "$BRIEF" \
      && echo "TURN_RESULT=goose run OK (lane: ${GOOSE_MODEL})" \
      || echo "TURN_RESULT=BLOCKED (goose run failed — Release Engineer's next turn repairs the harness)"
    ;;
esac
