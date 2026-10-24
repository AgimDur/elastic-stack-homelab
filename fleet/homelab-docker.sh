#!/usr/bin/env bash
# Policy-as-Code: legt die Fleet-Policy homelab-docker an (System + Docker, Feld umgebung=lab).
# Aufruf aus dem Repo: ./fleet/homelab-docker.sh
set -euo pipefail
cd "$(dirname "$0")/.."
PW=$(grep '^ELASTIC_PASSWORD=' .env | cut -d= -f2)
KB=http://localhost:5601

kb() { curl -sS --fail-with-body -u "elastic:$PW" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' "$@"; echo; }

kb -X POST "$KB/api/fleet/epm/packages/docker/2.16.0"

kb -X POST "$KB/api/fleet/agent_policies?sys_monitoring=true" -d '{
  "id": "homelab-docker", "name": "homelab-docker",
  "description": "Homelab: System plus Docker-Container", "namespace": "default",
  "monitoring_enabled": ["logs", "metrics"],
  "global_data_tags": [{ "name": "umgebung", "value": "lab" }]
}'

kb -X POST "$KB/api/fleet/package_policies" -d '{
  "policy_ids": ["homelab-docker"], "name": "docker-1", "namespace": "default",
  "package": { "name": "docker", "version": "2.16.0" }
}'
