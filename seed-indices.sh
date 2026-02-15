#!/usr/bin/env bash
set -e

ES="http://localhost:9200"

echo "Creating demo indices..."

# Older indices
for d in 30 20 10; do
  name="logs-2024.12.$((31-d))"
  curl -s -X PUT "$ES/$name" -H 'Content-Type: application/json' -d '{}'
  echo "Created $name"
  sleep 1
done

# New indices
for d in 01 02 03; do
  name="logs-2025.01.$d"
  curl -s -X PUT "$ES/$name" -H 'Content-Type: application/json' -d '{}'
  echo "Created $name"
  sleep 1
done

echo "Done."
