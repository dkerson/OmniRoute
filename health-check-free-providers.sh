#!/bin/bash
# OmniRoute Free Provider Health Check
# Runs every 5 min via cron, tests free providers.
#
# For felo-web specifically (one of the two no-auth providers in
# AUTO_COMBO_NOAUTH_ALLOWLIST in open-sse/services/autoCombo/virtualFactory.ts,
# alongside opencode), this script toggles its own provider_connections row's
# is_active flag. That is the ONLY lever that excludes a specific no-auth
# provider from auto/* without collateral damage: the auto_candidate_overrides
# table (per-API-key, connectionId-based) CANNOT do this selectively for
# no-auth providers, because every no-auth candidate (felo-web AND opencode)
# shares one synthetic connectionId ("noauth") - excluding by connectionId
# there would silently take down whichever of the two is still healthy along
# with the broken one. provider_connections.is_active is checked per-provider
# (disabledNoAuthProviders in virtualFactory.ts, keyed by `provider` column),
# so a row per provider is precise - no cross-provider damage.
# Confirmed empirically 2026-09-01: toggling this row takes effect on the very
# next request with no OmniRoute restart needed (no meaningful connection
# cache in front of provider_connections reads).
#
# #ffall-audit-2026-09-07, tried AND REVERTED same day: generalized the toggle
# to also cover opencode (toggle_noauth_connection(provider, status), used for
# both sources) because oc/* free models always fail (400/401) in
# auto/best-free, wasting ~5-6s per chat before falling through to Ollama.
# BROKE Sessao de Projeto within ~15min of deploy: opencode is the ONLY
# candidate in the auto/coding:free pool (tool-calling combo, used by Project
# Sessions - different from auto/best-free, the plain-chat combo felo-web
# shares with it). Disabling opencode drops auto/coding:free to 0 candidates,
# which fails FAST with a clean "capability_mismatch" error instead of the
# slow-but-eventually-successful internal cascade (coding:free -> best-free ->
# ffall-fallback/Ollama, ~20s, confirmed working via real traffic logs before
# this change) that used to recover real tool access for the user. The client
# then falls to FFALL's OWN client-side BYOK chain (Groq/OpenRouter free
# tier) instead, which answers fast but WITHOUT reliable tool-calling -
# strictly worse than the slow-but-working path it replaced. Reverted the
# opencode toggle call (kept only for felo-web, unaffected - felo-web is not
# the sole candidate of any tool-calling combo). See
# vault/wiki/arquitetura-fall-omniroute-analise-2026-09-07.md secao 11.12/11.13
# before ever re-attempting this - would need the probe itself to send a
# tool-calling request (not plain chat) and a check that no combo depends on
# opencode as its only candidate.
#
# theoldllm/zcode/auggie/duckduckgo are tested here too (useful signal in the
# log) but are NOT part of the auto/best-free pool at all (not in the
# allowlist), so toggling them would have zero effect on real chat traffic -
# intentionally left log-only.

set -euo pipefail

# #ffall-audit-2026-09-07: era "http://localhost:20131" - quebrou silenciosamente
# quando docker-compose.prod.yml passou a publicar a porta 20131 so' em
# 10.10.0.1 (WireGuard), nao mais em 0.0.0.0/127.0.0.1 (fix de seguranca desta
# mesma auditoria, commit 1c1e4fb87). Resultado: TODO run do cron (5/5min)
# desde a recriacao do container reportou "failed" pra TODOS os providers
# (incluindo Ollama), mesmo com trafego real funcionando normalmente via
# 10.10.0.1 - confirmado comparando curl direto (localhost=exit7/connection
# refused, 10.10.0.1=HTTP 401 sem auth, ou seja alcancavel) com os logs reais
# do container (requests de producao concluindo com sucesso no mesmo periodo).
# O proprio health-check roda NO host VP6 (nao dentro do container docker),
# entao precisa do IP WireGuard como qualquer outro cliente externo.
OMNIROUTE_API="http://10.10.0.1:20131/v1/chat/completions"
# #ffall-audit-2026-09: token estava hardcoded aqui em texto plano, num script
# world-readable (-rwxr-xr-x) rodando via cron a cada 5min. Le do .env real
# agora (que ja tinha o mesmo valor sob OMNIROUTE_API_KEY, tambem corrigido
# pra chmod 600 nesta mesma auditoria) em vez de duplicar o secret aqui.
OMNIROUTE_TOKEN="$(grep -E '^OMNIROUTE_API_KEY=' /opt/omniroute/.env | cut -d= -f2-)"
if [ -z "$OMNIROUTE_TOKEN" ]; then
  echo "FATAL: OMNIROUTE_API_KEY nao encontrado em /opt/omniroute/.env" >&2
  exit 1
fi
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

# Toggle a no-auth provider's own provider_connections.is_active based on
# its latest probe result. Idempotent - safe to run every 5 min forever.
# Used for felo-web and opencode (the two providers in
# AUTO_COMBO_NOAUTH_ALLOWLIST) - each gets its OWN row keyed by `provider`,
# so disabling one never touches the other even though both share the same
# synthetic noauth connectionId at request time.
toggle_noauth_connection() {
  local provider="$1"
  local status="$2"
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  local existing_id
  existing_id=$(sqlite3 "$SQLITE_DB" "SELECT id FROM provider_connections WHERE provider='${provider}' ORDER BY created_at DESC LIMIT 1;" 2>/dev/null || echo "")

  if [ "$status" = "healthy" ]; then
    if [ -n "$existing_id" ]; then
      local is_active
      is_active=$(sqlite3 "$SQLITE_DB" "SELECT is_active FROM provider_connections WHERE id='${existing_id}';" 2>/dev/null || echo "1")
      if [ "$is_active" = "0" ]; then
        sqlite3 "$SQLITE_DB" "UPDATE provider_connections SET is_active=1, updated_at='${now}', test_status='healthy', last_error=NULL WHERE id='${existing_id}';"
        log "${provider} RE-ENABLED in auto/* pool (health check passed)"
      fi
    fi
    return
  fi

  # Not healthy: ensure it's disabled.
  if [ -z "$existing_id" ]; then
    local new_id
    new_id=$(cat /proc/sys/kernel/random/uuid)
    sqlite3 "$SQLITE_DB" "INSERT INTO provider_connections (id, provider, auth_type, display_name, is_active, created_at, updated_at, test_status, last_error) VALUES ('${new_id}', '${provider}', 'noauth-toggle', '${provider} (auto-managed by health-check)', 0, '${now}', '${now}', '${status}', 'Auto-disabled by health-check: ${status}');"
    log "${provider} DISABLED in auto/* pool (health check: ${status})"
  else
    local is_active
    is_active=$(sqlite3 "$SQLITE_DB" "SELECT is_active FROM provider_connections WHERE id='${existing_id}';" 2>/dev/null || echo "1")
    if [ "$is_active" = "1" ]; then
      sqlite3 "$SQLITE_DB" "UPDATE provider_connections SET is_active=0, updated_at='${now}', test_status='${status}', last_error='Auto-disabled by health-check: ${status}' WHERE id='${existing_id}';"
      log "${provider} DISABLED in auto/* pool (health check: ${status})"
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
    toggle_noauth_connection "felo-web" "$status"
  fi
  # #ffall-audit-2026-09-07-revert: NAO chamar toggle_noauth_connection pro
  # opencode aqui. Diferente do felo-web, opencode e' o UNICO candidato do
  # combo auto/coding:free (tool-calling, usado pela Sessao de Projeto) - a
  # sonda deste script usa oc/deepseek-v4-flash-free SEM tools (chat simples),
  # que sempre falha 400 ("OpenCode's free tier can only be used in OpenCode"),
  # entao desabilitar por esse sinal zera o pool de auto/coding:free de vez
  # (poolSize=0, erro imediato "no target supports tool calling"). Confirmado
  # ao vivo: antes disso, auto/coding:free com opencode como candidato FALHAVA
  # tambem, mas o OmniRoute cascateava internamente coding:free -> best-free
  # -> ffall-fallback (Ollama, que tem ferramentas reais) - lento (~20s) mas
  # funcional. Depois de desabilitar, essa cascata parou de acontecer e o
  # cliente (FFALL local) caia direto pro fallback BYOK client-side
  # (Groq/OpenRouter), que responde rapido mas SEM acesso confiavel a
  # ferramentas do projeto - regressao pior que o problema original.
  # Reproduzir esse fix com seguranca exigiria testar o probe COM tools (nao
  # so' chat simples) e confirmar que nenhum outro combo depende de opencode
  # como unico candidato antes de reativar - nao feito ainda. Ver
  # vault/wiki/arquitetura-fall-omniroute-analise-2026-09-07.md secao 11.12.

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
