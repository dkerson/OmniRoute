#!/bin/bash
# OmniRoute Free Provider Health Check
# Runs every 5 min via cron, tests free providers.
#
# For felo-web specifically (the only no-auth provider besides opencode that
# is allowlisted into the auto/* candidate pool - see AUTO_COMBO_NOAUTH_ALLOWLIST
# in open-sse/services/autoCombo/virtualFactory.ts), this script also toggles
# its own provider_connections row's is_active flag. That is the ONLY lever
# that excludes a specific no-auth provider from auto/* without collateral
# damage: the auto_candidate_overrides table (per-API-key, connectionId-based)
# CANNOT do this selectively for no-auth providers, because every no-auth
# candidate (felo-web AND opencode) shares one synthetic connectionId
# ("noauth") - excluding by connectionId there would silently kill opencode's
# free models too. provider_connections.is_active is checked per-provider
# (disabledNoAuthProviders in virtualFactory.ts), so it is precise.
# Confirmed empirically 2026-09-01: toggling this row takes effect on the very
# next request with no OmniRoute restart needed (no meaningful connection cache
# in front of provider_connections reads).
#
# theoldllm/zcode/auggie/duckduckgo are tested here too (useful signal in the
# log) but are NOT part of the auto/best-free pool at all (not in the
# allowlist), so toggling them would have zero effect on real chat traffic -
# intentionally left log-only.

set -euo pipefail

OMNIROUTE_API="http://localhost:20131/v1/chat/completions"
OMNIROUTE_TOKEN="11235726ab739804eb108c27c41b76585491e50c12f0d0f6d70fc369dcf068e2"
SQLITE_DB="/var/lib/docker/volumes/omniroute-prod-data/_data/storage.sqlite"
LOG_FILE="/var/log/omniroute-health-check.log"

# Representative free models to test (one per source)
declare -A FREE_MODELS=(
  ["ddgw/gpt-5.4-mini"]="duckduckgo"
  ["felo/felo-chat"]="felo"
  ["oc/deepseek-v4-flash-free"]="opencode"
  ["tllm/GPT_5_4"]="theoldllm"
  ["aug/gpt5.4-mini"]="auggie"
  ["zc/glm-5.2"]="zcode"
)

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG_FILE"
}

# Test a single model with a minimal prompt
test_model() {
  local model="$1"
  local payload="{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1,\"stream\":false}"

  local response
  local http_code

  # #P9.9: 15s -> 25s. O probe do fallback de codigo (qwen2.5-coder) as vezes
  # precisa de cold-load (~7-10s) + geracao - com 15s o proprio curl do
  # health-check desistia antes do OmniRoute confirmar sucesso, reportando
  # "failed" mesmo quando a chamada real ia terminar bem logo em seguida.
  response=$(curl -s -w "\n%{http_code}" -m 25 -X POST "$OMNIROUTE_API" \
    -H "Authorization: Bearer $OMNIROUTE_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null) || true

  http_code=$(echo "$response" | tail -1)
  local body=$(echo "$response" | head -n -1)

  if [ "$http_code" = "200" ]; then
    echo "healthy"
  elif echo "$body" | grep -q "429\|rate_limit\|rate limit"; then
    echo "rate_limited"
  elif echo "$body" | grep -q "401\|403\|auth"; then
    echo "auth_error"
  elif echo "$body" | grep -q "ALL_TARGETS_SKIPPED\|all_targets_skipped"; then
    echo "all_skipped"
  else
    echo "failed"
  fi
}

# Toggle felo-web's own provider_connections.is_active based on the latest
# felo/felo-chat probe result. Idempotent - safe to run every 5 min forever.
toggle_felo_web_connection() {
  local status="$1"
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  local existing_id
  existing_id=$(sqlite3 "$SQLITE_DB" "SELECT id FROM provider_connections WHERE provider='felo-web' ORDER BY created_at DESC LIMIT 1;" 2>/dev/null || echo "")

  if [ "$status" = "healthy" ]; then
    if [ -n "$existing_id" ]; then
      local is_active
      is_active=$(sqlite3 "$SQLITE_DB" "SELECT is_active FROM provider_connections WHERE id='${existing_id}';" 2>/dev/null || echo "1")
      if [ "$is_active" = "0" ]; then
        sqlite3 "$SQLITE_DB" "UPDATE provider_connections SET is_active=1, updated_at='${now}', test_status='healthy', last_error=NULL WHERE id='${existing_id}';"
        log "felo-web RE-ENABLED in auto/* pool (health check passed)"
      fi
    fi
    return
  fi

  # Not healthy: ensure it's disabled.
  if [ -z "$existing_id" ]; then
    local new_id
    new_id=$(cat /proc/sys/kernel/random/uuid)
    sqlite3 "$SQLITE_DB" "INSERT INTO provider_connections (id, provider, auth_type, display_name, is_active, created_at, updated_at, test_status, last_error) VALUES ('${new_id}', 'felo-web', 'noauth-toggle', 'felo-web (auto-managed by health-check)', 0, '${now}', '${now}', '${status}', 'Auto-disabled by health-check: ${status}');"
    log "felo-web DISABLED in auto/* pool (health check: ${status})"
  else
    local is_active
    is_active=$(sqlite3 "$SQLITE_DB" "SELECT is_active FROM provider_connections WHERE id='${existing_id}';" 2>/dev/null || echo "1")
    if [ "$is_active" = "1" ]; then
      sqlite3 "$SQLITE_DB" "UPDATE provider_connections SET is_active=0, updated_at='${now}', test_status='${status}', last_error='Auto-disabled by health-check: ${status}' WHERE id='${existing_id}';"
      log "felo-web DISABLED in auto/* pool (health check: ${status})"
    else
      sqlite3 "$SQLITE_DB" "UPDATE provider_connections SET updated_at='${now}', test_status='${status}' WHERE id='${existing_id}';"
    fi
  fi
}

# Main health check
log "=== Health check started ==="

healthy_count=0
rate_limited_count=0
failed_count=0

for model in "${!FREE_MODELS[@]}"; do
  source="${FREE_MODELS[$model]}"
  status=$(test_model "$model")
  log "Model: $model (source: $source) -> Status: $status"

  if [ "$source" = "felo" ]; then
    toggle_felo_web_connection "$status"
  fi

  case "$status" in
    healthy)
      healthy_count=$((healthy_count + 1))
      ;;
    rate_limited|auth_error|all_skipped|failed)
      rate_limited_count=$((rate_limited_count + 1))
      ;;
  esac
done

log "Summary: $healthy_count healthy, $rate_limited_count unhealthy"

# Check Ollama fallback
ollama_status=$(test_model "ffall-fallback")
log "Ollama fallback (ffall-fallback) -> Status: $ollama_status"

if [ "$ollama_status" != "healthy" ]; then
  log "WARNING: Ollama fallback is not healthy!"
fi

# #P9.9: o fallback de codigo (qwen2.5-coder, usado quando allow_local_coder_llm
# esta ligado e a pergunta parece ser sobre codigo) nao era mantido aquecido
# por este script - so o ffall-fallback (llama3.1:8b) era pingado a cada 5min.
# Ollama descarrega um modelo da memoria depois de ~5min sem uso, entao
# qwen2.5-coder ficava frio toda vez que ficava mais de 5min sem trafego real,
# e o cold-load (~7-10s) somado ao tempo de resposta estourava o timeout de
# 15s do OmniRoute (confirmado: 504 gateway_timeout em producao). Mesma logica
# de aquecimento do ffall-fallback, agora tambem pro modelo de codigo.
ollama_code_status=$(test_model "ffall-fallback-code")
log "Ollama code fallback (ffall-fallback-code) -> Status: $ollama_code_status"

if [ "$ollama_code_status" != "healthy" ]; then
  log "WARNING: Ollama code fallback is not healthy!"
fi

log "=== Health check completed ==="
