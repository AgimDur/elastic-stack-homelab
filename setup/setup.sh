#!/bin/bash
# Läuft einmal im Container "setup": CA + Zertifikate erzeugen, kibana_system-Passwort setzen.
set -e
cd /usr/share/elasticsearch

# 1. Passwörter vorhanden?
if [ -z "$ELASTIC_PASSWORD" ] || [ -z "$KIBANA_PASSWORD" ]; then
  echo "ELASTIC_PASSWORD / KIBANA_PASSWORD fehlen in .env"; exit 1
fi

# 2. CA nur einmal erzeugen
if [ ! -f config/certs/ca/ca.crt ]; then
  echo "Erzeuge CA"
  bin/elasticsearch-certutil ca --silent --pem -out config/certs/ca.zip
  unzip -q config/certs/ca.zip -d config/certs
fi

# 3. Zertifikate nur einmal erzeugen
if [ ! -f config/certs/es01/es01.crt ]; then
  echo "Erzeuge Zertifikate"
  bin/elasticsearch-certutil cert --silent --pem --in /setup/instances.yml \
    --ca-cert config/certs/ca/ca.crt --ca-key config/certs/ca/ca.key \
    -out config/certs/certs.zip
  unzip -q config/certs/certs.zip -d config/certs
fi

chown -R root:root config/certs
find config/certs -type d -exec chmod 750 {} \;
find config/certs -type f -exec chmod 640 {} \;

# 4. Warten, bis es01 antwortet, dann kibana_system-Passwort setzen
echo "Warte auf es01"
until curl -s --cacert config/certs/ca/ca.crt https://es01:9200 | grep -q "missing authentication credentials"; do sleep 5; done

echo "Setze Passwort fuer kibana_system"
until curl -s -X POST --cacert config/certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" \
  -H "Content-Type: application/json" https://es01:9200/_security/user/kibana_system/_password \
  -d "{\"password\":\"${KIBANA_PASSWORD}\"}" | grep -q "^{}"; do sleep 5; done

echo "Setup fertig"
