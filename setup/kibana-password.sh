#!/bin/bash
# Container "kibana-password": läuft, wenn es01 healthy ist. Setzt das Passwort für kibana_system.
set -e
if [ -z "$ELASTIC_PASSWORD" ] || [ -z "$KIBANA_PASSWORD" ]; then
  echo "ELASTIC_PASSWORD / KIBANA_PASSWORD fehlen in .env"; exit 1
fi

until curl -s -X POST --cacert config/certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" \
  -H "Content-Type: application/json" https://es01:9200/_security/user/kibana_system/_password \
  -d "{\"password\":\"${KIBANA_PASSWORD}\"}" | grep -q "^{}"; do sleep 5; done
echo "Passwort fuer kibana_system gesetzt"
