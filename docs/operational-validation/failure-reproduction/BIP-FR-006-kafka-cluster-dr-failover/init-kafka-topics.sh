#!/bin/sh
set -eu

bootstrap="${KAFKA_BOOTSTRAP_SERVERS:?required}"
rf="${TOPIC_REPLICATION_FACTOR:?required}"
min_isr="${TOPIC_MIN_ISR:?required}"

attempt=0
until kafka-broker-api-versions --bootstrap-server "$bootstrap" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 60 ] || exit 1
  sleep 2
done

for topic in barcode-events barcode-events-dlt; do
  kafka-topics --bootstrap-server "$bootstrap" --create --if-not-exists \
    --topic "$topic" --partitions 3 --replication-factor "$rf" \
    --config "min.insync.replicas=$min_isr"
  kafka-topics --bootstrap-server "$bootstrap" --describe --topic "$topic"
done
