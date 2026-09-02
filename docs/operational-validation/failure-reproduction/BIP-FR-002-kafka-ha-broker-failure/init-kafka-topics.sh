#!/bin/sh

set -eu

bootstrap_servers="${KAFKA_BOOTSTRAP_SERVERS:?KAFKA_BOOTSTRAP_SERVERS is required}"
max_attempts="${TOPIC_INIT_MAX_ATTEMPTS:-60}"

wait_for_cluster() {
  attempt=1
  while [ "$attempt" -le "$max_attempts" ]; do
    if kafka-broker-api-versions --bootstrap-server "$bootstrap_servers" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    attempt=$((attempt + 1))
  done

  echo "Kafka cluster did not become reachable after $max_attempts attempts" >&2
  return 1
}

create_contract_topic() {
  topic_name="$1"

  kafka-topics \
    --bootstrap-server "$bootstrap_servers" \
    --create \
    --if-not-exists \
    --topic "$topic_name" \
    --partitions 3 \
    --replication-factor 3 \
    --config min.insync.replicas=2
}

topic_contract_is_ready() {
  topic_name="$1"
  description="$(kafka-topics \
    --bootstrap-server "$bootstrap_servers" \
    --describe \
    --topic "$topic_name" 2>/dev/null)" || return 1
  configuration="$(kafka-configs \
    --bootstrap-server "$bootstrap_servers" \
    --describe \
    --entity-type topics \
    --entity-name "$topic_name" 2>/dev/null)" || return 1
  under_replicated="$(kafka-topics \
    --bootstrap-server "$bootstrap_servers" \
    --describe \
    --under-replicated-partitions \
    --topic "$topic_name" 2>/dev/null)" || return 1
  unavailable="$(kafka-topics \
    --bootstrap-server "$bootstrap_servers" \
    --describe \
    --unavailable-partitions \
    --topic "$topic_name" 2>/dev/null)" || return 1

  printf '%s\n' "$description" | grep -Eq 'PartitionCount:[[:space:]]*3([[:space:]]|$)' || return 1
  printf '%s\n' "$description" | grep -Eq 'ReplicationFactor:[[:space:]]*3([[:space:]]|$)' || return 1
  [ "$(printf '%s\n' "$description" | grep -c 'Partition:')" -eq 3 ] || return 1
  printf '%s\n' "$configuration" | grep -Eq 'min\.insync\.replicas=2([[:space:],]|$)' || return 1
  ! printf '%s\n' "$under_replicated" | grep -q 'Partition:' || return 1
  ! printf '%s\n' "$unavailable" | grep -q 'Partition:' || return 1
}

wait_for_topic_contract() {
  topic_name="$1"
  attempt=1

  while [ "$attempt" -le "$max_attempts" ]; do
    if topic_contract_is_ready "$topic_name"; then
      kafka-topics --bootstrap-server "$bootstrap_servers" --describe --topic "$topic_name"
      kafka-configs \
        --bootstrap-server "$bootstrap_servers" \
        --describe \
        --entity-type topics \
        --entity-name "$topic_name"
      return 0
    fi
    sleep 2
    attempt=$((attempt + 1))
  done

  echo "Topic $topic_name did not satisfy partitions=3, RF=3, minISR=2 with full ISR" >&2
  return 1
}

wait_for_cluster

# Processing의 DLT publish 경로도 automatic topic creation에 의존하지 않게 같은
# availability 경계로 미리 만든다. BIP-FR-002의 승인 대상 토픽은 barcode-events다.
create_contract_topic barcode-events
create_contract_topic barcode-events-dlt

wait_for_topic_contract barcode-events
wait_for_topic_contract barcode-events-dlt
