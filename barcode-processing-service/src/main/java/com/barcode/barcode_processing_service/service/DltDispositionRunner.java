package com.barcode.barcode_processing_service.service;

import java.time.Duration;
import java.util.Collection;
import java.util.List;
import java.util.Map;

import org.apache.kafka.clients.consumer.Consumer;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.OffsetAndMetadata;
import org.apache.kafka.common.TopicPartition;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.context.annotation.Profile;
import org.springframework.kafka.core.ConsumerFactory;
import org.springframework.stereotype.Component;

import com.barcode.barcode_processing_service.recovery.DispositionOutcome;

import lombok.extern.slf4j.Slf4j;

/**
 * 실행 시작 시 보이는 DLT backlog의 end offset을 경계로 삼아 한 번만 처리한다.
 * 각 출력 발행이 확인된 레코드만 commitSync로 정산한다.
 */
@Slf4j
@Component
@Profile("dlt-disposition")
public class DltDispositionRunner implements ApplicationRunner {

    private final ConsumerFactory<?, ?> consumerFactory;
    private final DltDispositionService dispositionService;
    private final String dltTopic;
    private final String groupId;
    private final Duration assignmentTimeout;
    private final Duration pollTimeout;

    public DltDispositionRunner(
        ConsumerFactory<?, ?> consumerFactory,
        DltDispositionService dispositionService,
        @Value("${bip.dlt.topic:barcode-events-dlt}") String dltTopic,
        @Value("${bip.dlt.group-id:barcode-events-dlt-disposition}") String groupId,
        @Value("${bip.dlt.assignment-timeout:30s}") Duration assignmentTimeout,
        @Value("${bip.dlt.poll-timeout:1s}") Duration pollTimeout
    ) {
        this.consumerFactory = consumerFactory;
        this.dispositionService = dispositionService;
        this.dltTopic = dltTopic;
        this.groupId = groupId;
        this.assignmentTimeout = assignmentTimeout;
        this.pollTimeout = pollTimeout;
    }

    @Override
    public void run(ApplicationArguments args) {
        long processed = 0L;
        if (consumerFactory.isAutoCommit()) {
            throw new IllegalStateException("DLT disposition requires enable.auto.commit=false");
        }
        try (Consumer<?, ?> consumer = consumerFactory.createConsumer(groupId, ".one-shot")) {
            consumer.subscribe(List.of(dltTopic));
            Collection<TopicPartition> assignment = awaitAssignment(consumer);
            int topicPartitionCount = consumer.partitionsFor(dltTopic).size();
            if (assignment.size() != topicPartitionCount) {
                throw new IllegalStateException(
                    "DLT one-shot disposition must exclusively own every topic partition");
            }
            resetToCommittedPositions(consumer, assignment);
            Map<TopicPartition, Long> backlogEndOffsets = consumer.endOffsets(assignment);

            log.info("dltDisposition status=STARTED topic={} groupId={} backlogEndOffsets={}",
                dltTopic, groupId, backlogEndOffsets);

            while (!backlogComplete(consumer, backlogEndOffsets)) {
                ConsumerRecords<?, ?> records = consumer.poll(pollTimeout);
                if (!consumer.assignment().equals(backlogEndOffsets.keySet())) {
                    throw new IllegalStateException(
                        "DLT assignment changed during one-shot disposition; refusing partial completion");
                }
                for (ConsumerRecord<?, ?> record : records) {
                    if (withinFrozenBacklog(record, backlogEndOffsets)) {
                        processAndCommit(record, consumer);
                        processed++;
                    }
                }
            }

            log.info("dltDisposition status=COMPLETED topic={} groupId={} processedRecords={}",
                dltTopic, groupId, processed);
        } catch (RuntimeException e) {
            log.error("dltDisposition status=FAILED topic={} groupId={} processedRecords={}",
                dltTopic, groupId, processed, e);
            throw e;
        }
    }

    void processAndCommit(ConsumerRecord<?, ?> record, Consumer<?, ?> consumer) {
        DispositionOutcome outcome = dispositionService.dispose(record);
        TopicPartition partition = new TopicPartition(record.topic(), record.partition());
        try {
            consumer.commitSync(Map.of(partition, new OffsetAndMetadata(record.offset() + 1L)));
        } catch (RuntimeException e) {
            dispositionService.logSettlementFailed(record, outcome, e);
            throw e;
        }
        dispositionService.logSettled(record, outcome);
    }

    private Collection<TopicPartition> awaitAssignment(Consumer<?, ?> consumer) {
        long deadline = System.nanoTime() + assignmentTimeout.toNanos();
        while (consumer.assignment().isEmpty() && System.nanoTime() < deadline) {
            consumer.poll(Duration.ofMillis(250));
        }
        if (consumer.assignment().isEmpty()) {
            throw new IllegalStateException("Timed out waiting for DLT partition assignment");
        }
        return List.copyOf(consumer.assignment());
    }

    private void resetToCommittedPositions(
        Consumer<?, ?> consumer,
        Collection<TopicPartition> assignment
    ) {
        Map<TopicPartition, OffsetAndMetadata> committed = consumer.committed(assignment.stream().collect(
            java.util.stream.Collectors.toSet()));
        Map<TopicPartition, Long> beginnings = consumer.beginningOffsets(assignment);
        Map<TopicPartition, Long> ends = consumer.endOffsets(assignment);

        for (TopicPartition partition : assignment) {
            OffsetAndMetadata saved = committed.get(partition);
            long beginning = beginnings.get(partition);
            long end = ends.get(partition);
            long position = saved == null ? beginning : Math.max(beginning, Math.min(saved.offset(), end));
            consumer.seek(partition, position);
        }
    }

    boolean withinFrozenBacklog(
        ConsumerRecord<?, ?> record,
        Map<TopicPartition, Long> endOffsets
    ) {
        TopicPartition partition = new TopicPartition(record.topic(), record.partition());
        Long backlogEnd = endOffsets.get(partition);
        return backlogEnd != null && record.offset() < backlogEnd;
    }

    boolean backlogComplete(Consumer<?, ?> consumer, Map<TopicPartition, Long> endOffsets) {
        for (Map.Entry<TopicPartition, Long> entry : endOffsets.entrySet()) {
            if (consumer.position(entry.getKey()) < entry.getValue()) {
                return false;
            }
        }
        return true;
    }
}
