#!/bin/bash
# Container "certs": CA und Zertifikate erzeugen (nur wenn noch nicht vorhanden), dann beenden.
set -e
cd /usr/share/elasticsearch

if [ ! -f config/certs/ca/ca.crt ]; then
  echo "Erzeuge CA"
  bin/elasticsearch-certutil ca --silent --pem -out config/certs/ca.zip
  unzip -q config/certs/ca.zip -d config/certs
fi

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
echo "Zertifikate bereit"
