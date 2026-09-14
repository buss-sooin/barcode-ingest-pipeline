package com.barcode.barcode_processing_service.service;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.header.Header;
import org.apache.kafka.common.header.Headers;
import org.apache.kafka.common.header.internals.RecordHeaders;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.KafkaHeaders;
import org.springframework.stereotype.Service;

import com.barcode.barcode_processing_service.recovery.DispositionOutcome;
import com.barcode.barcode_processing_service.recovery.DispositionResult;
import com.barcode.barcode_processing_service.recovery.DltDispositionPublicationException;
import com.barcode.barcode_processing_service.recovery.DltHeaders;
import com.barcode.barcode_processing_service.recovery.FailureCategory;

import lombok.extern.slf4j.Slf4j;

@Slf4j
@Service
@Profile("dlt-disposition")
public class DltDispositionService {

    private final KafkaTemplate<Object, Object> kafkaTemplate;
    private final String replayTopic;
    private final String quarantineTopic;
    private final int maxReplayAttempts;
    private final Duration publicationTimeout;

    public DltDispositionService(
        KafkaTemplate<Object, Object> kafkaTemplate,
        @Value("${bip.dlt.replay-topic:barcode-events}") String replayTopic,
        @Value("${bip.dlt.quarantine-topic:barcode-events-quarantine}") String quarantineTopic,
        @Value("${bip.dlt.max-replay-attempts:1}") int maxReplayAttempts,
        @Value("${bip.dlt.publication-timeout:30s}") Duration publicationTimeout
    ) {
        this.kafkaTemplate = kafkaTemplate;
        this.replayTopic = replayTopic;
        this.quarantineTopic = quarantineTopic;
        if (maxReplayAttempts != 1) {
            throw new IllegalArgumentException("MAX_DLT_REPLAY_ATTEMPTS must be 1 for BIP-FR-005");
        }
        this.maxReplayAttempts = maxReplayAttempts;
        this.publicationTimeout = publicationTimeout;
    }

    public DispositionOutcome dispose(ConsumerRecord<?, ?> dltRecord) {
        FailureCategory category = failureCategory(dltRecord.headers());
        ReplayCount replayCount = replayCount(dltRecord.headers());
        DispositionPlan plan = plan(category, replayCount);
        ProducerRecord<Object, Object> output = outputRecord(dltRecord, category, plan);

        try {
            kafkaTemplate.send(output).get(publicationTimeout.toMillis(), TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            logFailed(dltRecord, category, replayCount.value(), plan, e);
            throw new DltDispositionPublicationException("DLT disposition publication interrupted", e);
        } catch (ExecutionException | TimeoutException | RuntimeException e) {
            logFailed(dltRecord, category, replayCount.value(), plan, e);
            throw new DltDispositionPublicationException("DLT disposition publication failed", e);
        }

        DispositionOutcome outcome = new DispositionOutcome(
            plan.result(), category, plan.outputReplayCount(), plan.quarantineReason());
        return outcome;
    }

    void logSettled(ConsumerRecord<?, ?> dltRecord, DispositionOutcome outcome) {
        log.info(
            "dltDisposition result={} originalTopic={} originalPartition={} originalOffset={} "
                + "dltTopic={} dltPartition={} dltOffset={} failureCategory={} replayCount={} quarantineReason={}",
            outcome.result(), originalTopic(dltRecord.headers()), originalPartition(dltRecord.headers()),
            originalOffset(dltRecord.headers()), dltRecord.topic(), dltRecord.partition(), dltRecord.offset(),
            outcome.failureCategory(), outcome.replayCount(), outcome.quarantineReason());
    }

    void logSettlementFailed(
        ConsumerRecord<?, ?> dltRecord,
        DispositionOutcome outcome,
        RuntimeException failure
    ) {
        log.error(
            "dltDisposition result=FAILED intendedResult={} originalTopic={} originalPartition={} "
                + "originalOffset={} dltTopic={} dltPartition={} dltOffset={} failureCategory={} "
                + "replayCount={} quarantineReason={} failureStage=OFFSET_COMMIT",
            outcome.result(), originalTopic(dltRecord.headers()), originalPartition(dltRecord.headers()),
            originalOffset(dltRecord.headers()), dltRecord.topic(), dltRecord.partition(), dltRecord.offset(),
            outcome.failureCategory(), outcome.replayCount(), outcome.quarantineReason(), failure);
    }

    private DispositionPlan plan(FailureCategory category, ReplayCount replayCount) {
        if (!replayCount.valid()) {
            return DispositionPlan.quarantine(replayCount.value(), "INVALID_REPLAY_COUNT");
        }
        if (replayCount.value() >= maxReplayAttempts) {
            return DispositionPlan.quarantine(replayCount.value(), "REPLAY_EXHAUSTED");
        }
        if (category == FailureCategory.TRANSIENT_REDIS) {
            return DispositionPlan.replay(replayCount.value() + 1);
        }
        if (category == FailureCategory.PERMANENT_VALIDATION) {
            return DispositionPlan.quarantine(replayCount.value(), "PERMANENT_VALIDATION");
        }
        return DispositionPlan.quarantine(replayCount.value(), "UNKNOWN_FAILURE");
    }

    private ProducerRecord<Object, Object> outputRecord(
        ConsumerRecord<?, ?> dltRecord,
        FailureCategory category,
        DispositionPlan plan
    ) {
        RecordHeaders headers = new RecordHeaders(dltRecord.headers().toArray());
        replaceHeader(headers, DltHeaders.FAILURE_CATEGORY, category.name());
        replaceHeader(headers, DltHeaders.REPLAY_COUNT, Integer.toString(plan.outputReplayCount()));
        String topic;

        if (plan.result() == DispositionResult.REPLAYED) {
            topic = replayTopic;
            headers.remove(DltHeaders.QUARANTINE_REASON);
            headers.remove(DltHeaders.SOURCE_DLT_TOPIC);
            headers.remove(DltHeaders.SOURCE_DLT_PARTITION);
            headers.remove(DltHeaders.SOURCE_DLT_OFFSET);
        } else {
            topic = quarantineTopic;
            replaceHeader(headers, DltHeaders.QUARANTINE_REASON, plan.quarantineReason());
            replaceHeader(headers, DltHeaders.SOURCE_DLT_TOPIC, dltRecord.topic());
            replaceHeader(headers, DltHeaders.SOURCE_DLT_PARTITION,
                Integer.toString(dltRecord.partition()));
            replaceHeader(headers, DltHeaders.SOURCE_DLT_OFFSET, Long.toString(dltRecord.offset()));
        }

        // partition=null: historical source partition을 재사용하지 않고 Kafka partitioner에 맡긴다.
        return new ProducerRecord<>(topic, null, dltRecord.key(), dltRecord.value(), headers);
    }

    private FailureCategory failureCategory(Headers headers) {
        Header header = headers.lastHeader(DltHeaders.FAILURE_CATEGORY);
        if (header == null) {
            return FailureCategory.UNKNOWN;
        }
        String value = asString(header);
        if (value == null) {
            return FailureCategory.UNKNOWN;
        }
        try {
            return FailureCategory.valueOf(value);
        } catch (IllegalArgumentException e) {
            return FailureCategory.UNKNOWN;
        }
    }

    private ReplayCount replayCount(Headers headers) {
        Header header = headers.lastHeader(DltHeaders.REPLAY_COUNT);
        if (header == null) {
            return new ReplayCount(0, true);
        }
        String value = asString(header);
        if (value == null) {
            return new ReplayCount(0, false);
        }
        try {
            int parsed = Integer.parseInt(value);
            return new ReplayCount(parsed >= 0 ? parsed : 0, parsed >= 0);
        } catch (NumberFormatException e) {
            return new ReplayCount(0, false);
        }
    }

    private String originalTopic(Headers headers) {
        Header header = firstHeader(headers, KafkaHeaders.DLT_ORIGINAL_TOPIC);
        String value = header == null ? null : asString(header);
        return value == null ? "UNKNOWN" : value;
    }

    private int originalPartition(Headers headers) {
        Header header = firstHeader(headers, KafkaHeaders.DLT_ORIGINAL_PARTITION);
        return header == null || header.value() == null || header.value().length != Integer.BYTES
            ? -1 : ByteBuffer.wrap(header.value()).getInt();
    }

    private long originalOffset(Headers headers) {
        Header header = firstHeader(headers, KafkaHeaders.DLT_ORIGINAL_OFFSET);
        return header == null || header.value() == null || header.value().length != Long.BYTES
            ? -1L : ByteBuffer.wrap(header.value()).getLong();
    }

    private Header firstHeader(Headers headers, String name) {
        for (Header header : headers.headers(name)) {
            return header;
        }
        return null;
    }

    private void replaceHeader(Headers headers, String name, String value) {
        headers.remove(name);
        headers.add(name, value.getBytes(StandardCharsets.UTF_8));
    }

    private String asString(Header header) {
        return header.value() == null ? null : new String(header.value(), StandardCharsets.UTF_8);
    }

    private void logFailed(
        ConsumerRecord<?, ?> record,
        FailureCategory category,
        int replayCount,
        DispositionPlan plan,
        Exception failure
    ) {
        log.error(
            "dltDisposition result=FAILED intendedResult={} originalTopic={} originalPartition={} "
                + "originalOffset={} dltTopic={} dltPartition={} dltOffset={} failureCategory={} "
                + "replayCount={} quarantineReason={}",
            plan.result(), originalTopic(record.headers()), originalPartition(record.headers()),
            originalOffset(record.headers()), record.topic(), record.partition(), record.offset(),
            category, replayCount, plan.quarantineReason(), failure);
    }

    private record ReplayCount(int value, boolean valid) {
    }

    private record DispositionPlan(
        DispositionResult result,
        int outputReplayCount,
        String quarantineReason
    ) {
        private static DispositionPlan replay(int replayCount) {
            return new DispositionPlan(DispositionResult.REPLAYED, replayCount, null);
        }

        private static DispositionPlan quarantine(int replayCount, String reason) {
            return new DispositionPlan(DispositionResult.QUARANTINED, replayCount, reason);
        }
    }
}
