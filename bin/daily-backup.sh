#!/bin/bash
# OmniRoute daily backup — snapshot do storage.sqlite + poda de snapshots
# antigos. Adicionado na auditoria 2026-09-04 (achado P0: zero backup
# automatizado real, ultimo snapshot manual estava com 2+ semanas).
set -euo pipefail

export DATA_DIR=/var/lib/docker/volumes/omniroute-prod-data/_data
BACKUPS_DIR="$DATA_DIR/db_backups"
LOG_FILE="/var/log/omniroute-daily-backup.log"
RETENTION_DAYS=14

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG_FILE"
}

log "=== Backup iniciado ==="

if /opt/omniroute/bin/snapshot-data.sh --label daily >> "$LOG_FILE" 2>&1; then
  log "Snapshot criado com sucesso"
else
  log "ERRO: snapshot-data.sh falhou"
  exit 1
fi

# Poda snapshots com mais de RETENTION_DAYS dias
pruned=0
if [ -d "$BACKUPS_DIR" ]; then
  while IFS= read -r -d '' dir; do
    rm -rf "$dir"
    pruned=$((pruned + 1))
    log "Removido snapshot antigo: $(basename "$dir")"
  done < <(find "$BACKUPS_DIR" -maxdepth 1 -type d -name 'snapshot_*' -mtime "+${RETENTION_DAYS}" -print0)
fi

log "Poda concluida: $pruned snapshot(s) removido(s) (retencao: ${RETENTION_DAYS}d)"
log "=== Backup concluido ==="
