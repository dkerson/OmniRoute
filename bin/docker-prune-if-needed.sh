#!/bin/bash
# Limpeza de disco preventiva - mesma logica do equivalente no V16
# (FFALL/app/scripts + /opt/ffall-monitor/docker-prune-if-needed.sh),
# aplicada aqui no VP6 pelo mesmo motivo: residuo de cache de build do
# Docker (BuildKit) e imagens antigas se acumula sem limpeza explicita.
# Achado da auditoria completa de infra 2026-09-07: disco do VP6 estava
# saudavel (55%, sem urgencia), mas ja tinha ~27GB reclamaveis (13.1GB
# imagens + 13.7GB build cache) e nenhuma limpeza automatica configurada -
# prevencao antes de virar problema, como aconteceu no V16 (chegou a 81%).
#
# So' limpa se o disco passar do limiar - evita rodar prune pesado todo
# dia a toa quando nao precisa.

set -euo pipefail

THRESHOLD_PERCENT=70
LOG_FILE="/var/log/omniroute-docker-prune.log"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG_FILE"
}

USED_PERCENT=$(df / --output=pcent | tail -1 | tr -dc '0-9')

if [ "$USED_PERCENT" -lt "$THRESHOLD_PERCENT" ]; then
  log "disco em ${USED_PERCENT}% (< ${THRESHOLD_PERCENT}%), nada a fazer"
  exit 0
fi

log "disco em ${USED_PERCENT}% (>= ${THRESHOLD_PERCENT}%), limpando cache de build e imagens nao usadas..."

BEFORE=$(df / --output=used | tail -1 | tr -d ' ')
docker builder prune -a -f >> "$LOG_FILE" 2>&1 || log "AVISO: docker builder prune falhou"
docker image prune -a -f >> "$LOG_FILE" 2>&1 || log "AVISO: docker image prune falhou"
AFTER_PERCENT=$(df / --output=pcent | tail -1 | tr -dc '0-9')
AFTER=$(df / --output=used | tail -1 | tr -d ' ')
FREED_KB=$((BEFORE - AFTER))

log "limpeza concluida: disco agora em ${AFTER_PERCENT}% (liberado ~$((FREED_KB / 1024 / 1024))GB)"
