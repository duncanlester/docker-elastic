#!/usr/bin/env bash
set -e

CONTAINER=es-demo

echo "Simulating high disk usage..."

docker exec -it $CONTAINER bash -c "
  fallocate -l 5G /usr/share/elasticsearch/data/fillfile || \
  dd if=/dev/zero of=/usr/share/elasticsearch/data/fillfile bs=1M count=5000
"

echo "Disk usage inside container:"
docker exec -it $CONTAINER df -h /usr/share/elasticsearch/data
