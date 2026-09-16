package com.barcode.barcode_processing_service.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.concurrent.CompletableFuture;

import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.header.Header;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.KafkaHeaders;

import com.barcode.barcode_processing_service.dto.BarcodeEvent;
import com.barcode.barcode_processing_service.recovery.DispositionResult;
import com.barcode.barcode_processing_service.recovery.DltDispositionPublicationException;
import com.barcode.barcode_processing_service.recovery.DltHeaders;
import com.barcode.barcode_processing_service.recovery.FailureCategory;

class DltDispositionServiceTest {

    private KafkaTemplate<Object, Object> kafkaTemplate;
    private DltDispositionService service;

    @SuppressWarnings("unchecked")
    @BeforeEach
    void setUp() {
        kafkaTemplate = mock(KafkaTemplate.class);
        when(kafkaTemplate.send(any(ProducerRecord.class)))
            .thenReturn(CompletableFuture.completedFuture(null));
        service = new DltDispositionService(
            kafkaTemplate,
            "barcode-events",
            "barcode-events-quarantine",
            1,
            Duration.ofSeconds(1));
    }

    @Test
    void unknownFailureIsQuarantinedWithLineage() {
        ConsumerRecord<String, BarcodeEvent> record = dltRecord(FailureCategory.UNKNOWN, null);

        var outcome = service.dispose(record);
        ProducerRecord<Object, Object> output = capturedOutput();

        assertThat(outcome.result()).isEqualTo(DispositionResult.QUARANTINED);
        assertThat(outcome.quarantineReason()).isEqualTo("UNKNOWN_FAILURE");
        assertThat(output.topic()).isEqualTo("barcode-events-quarantine");
        assertThat(header(output, DltHeaders.REPLAY_COUNT)).isEqualTo("0");
        assertThat(header(output, DltHeaders.FAILURE_CATEGORY)).isEqualTo("UNKNOWN");
        assertThat(header(output, DltHeaders.QUARANTINE_REASON)).isEqualTo("UNKNOWN_FAILURE");
        assertThat(header(output, DltHeaders.SOURCE_DLT_TOPIC)).isEqualTo("barcode-events-dlt");
        assertThat(header(output, DltHeaders.SOURCE_DLT_PARTITION)).isEqualTo("2");
        assertThat(header(output, DltHeaders.SOURCE_DLT_OFFSET)).isEqualTo("41");
    }

    @Test
    void firstTransientFailureIsReplayedWithIncrementedCountAndOriginalKey() {
        ConsumerRecord<String, BarcodeEvent> record =
            dltRecord(FailureCategory.TRANSIENT_REDIS, null);

        var outcome = service.dispose(record);
        ProducerRecord<Object, Object> output = capturedOutput();

        assertThat(outcome.result()).isEqualTo(DispositionResult.REPLAYED);
        assertThat(outcome.replayCount()).isEqualTo(1);
        assertThat(output.topic()).isEqualTo("barcode-events");
        assertThat(output.partition()).isNull();
        assertThat(output.key()).isEqualTo("device-1");
        assertThat(output.value()).isSameAs(record.value());
        assertThat(header(output, DltHeaders.REPLAY_COUNT)).isEqualTo("1");
    }

    @Test
    void replayExhaustionIsQuarantined() {
        ConsumerRecord<String, BarcodeEvent> record =
            dltRecord(FailureCategory.TRANSIENT_REDIS, "1");

        var outcome = service.dispose(record);

        assertThat(outcome.result()).isEqualTo(DispositionResult.QUARANTINED);
        assertThat(outcome.quarantineReason()).isEqualTo("REPLAY_EXHAUSTED");
        assertThat(capturedOutput().topic()).isEqualTo("barcode-events-quarantine");
    }

    @Test
    void permanentFailureIsDirectlyQuarantined() {
        ConsumerRecord<String, BarcodeEvent> record =
            dltRecord(FailureCategory.PERMANENT_VALIDATION, null);

        var outcome = service.dispose(record);

        assertThat(outcome.result()).isEqualTo(DispositionResult.QUARANTINED);
        assertThat(outcome.quarantineReason()).isEqualTo("PERMANENT_VALIDATION");
        assertThat(header(capturedOutput(), DltHeaders.REPLAY_COUNT)).isEqualTo("0");
    }

    @Test
    void nullValuedReplayCountIsInvalidAndQuarantinedWithSanitizedCount() {
        ConsumerRecord<String, BarcodeEvent> record =
            dltRecord(FailureCategory.TRANSIENT_REDIS, null);
        record.headers().add(DltHeaders.REPLAY_COUNT, null);

        var outcome = service.dispose(record);
        ProducerRecord<Object, Object> output = capturedOutput();

        assertThat(outcome.result()).isEqualTo(DispositionResult.QUARANTINED);
        assertThat(outcome.quarantineReason()).isEqualTo("INVALID_REPLAY_COUNT");
        assertThat(outcome.replayCount()).isZero();
        assertThat(header(output, DltHeaders.REPLAY_COUNT)).isEqualTo("0");
    }

    @Test
    void nullValuedFailureCategoryFailsClosedAsUnknown() {
        ConsumerRecord<String, BarcodeEvent> record = dltRecord(FailureCategory.UNKNOWN, null);
        record.headers().remove(DltHeaders.FAILURE_CATEGORY);
        record.headers().add(DltHeaders.FAILURE_CATEGORY, null);

        var outcome = service.dispose(record);
        ProducerRecord<Object, Object> output = capturedOutput();

        assertThat(outcome.result()).isEqualTo(DispositionResult.QUARANTINED);
        assertThat(outcome.failureCategory()).isEqualTo(FailureCategory.UNKNOWN);
        assertThat(outcome.quarantineReason()).isEqualTo("UNKNOWN_FAILURE");
        assertThat(header(output, DltHeaders.FAILURE_CATEGORY)).isEqualTo("UNKNOWN");
        assertThat(header(output, DltHeaders.REPLAY_COUNT)).isEqualTo("0");
    }

    @Test
    void rootOriginalIdentityAndFirstFailureTimestampArePreserved() {
        ConsumerRecord<String, BarcodeEvent> record =
            dltRecord(FailureCategory.TRANSIENT_REDIS, null);

        service.dispose(record);
        ProducerRecord<Object, Object> output = capturedOutput();

        assertThat(header(output, KafkaHeaders.DLT_ORIGINAL_TOPIC)).isEqualTo("barcode-events");
        assertThat(intHeader(output, KafkaHeaders.DLT_ORIGINAL_PARTITION)).isEqualTo(7);
        assertThat(longHeader(output, KafkaHeaders.DLT_ORIGINAL_OFFSET)).isEqualTo(101L);
        assertThat(header(output, DltHeaders.FIRST_FAILURE_AT)).isEqualTo("2026-09-09T00:00:00Z");
    }

    @Test
    void publicationFailureIsReportedAsFailedDisposition() {
        when(kafkaTemplate.send(any(ProducerRecord.class)))
            .thenReturn(CompletableFuture.failedFuture(new IllegalStateException("broker down")));

        assertThatThrownBy(() -> service.dispose(
            dltRecord(FailureCategory.TRANSIENT_REDIS, null)))
            .isInstanceOf(DltDispositionPublicationException.class)
            .hasMessage("DLT disposition publication failed");
    }

    private ConsumerRecord<String, BarcodeEvent> dltRecord(
        FailureCategory category,
        String replayCount
    ) {
        ConsumerRecord<String, BarcodeEvent> record = new ConsumerRecord<>(
            "barcode-events-dlt",
            2,
            41L,
            "device-1",
            new BarcodeEvent("barcode-1", 123L, "device-1"));
        record.headers().add(DltHeaders.FAILURE_CATEGORY, bytes(category.name()));
        record.headers().add(DltHeaders.FIRST_FAILURE_AT, bytes("2026-09-09T00:00:00Z"));
        record.headers().add(KafkaHeaders.DLT_ORIGINAL_TOPIC, bytes("barcode-events"));
        record.headers().add(KafkaHeaders.DLT_ORIGINAL_PARTITION,
            ByteBuffer.allocate(Integer.BYTES).putInt(7).array());
        record.headers().add(KafkaHeaders.DLT_ORIGINAL_OFFSET,
            ByteBuffer.allocate(Long.BYTES).putLong(101L).array());
        if (replayCount != null) {
            record.headers().add(DltHeaders.REPLAY_COUNT, bytes(replayCount));
        }
        return record;
    }

    @SuppressWarnings({"rawtypes", "unchecked"})
    private ProducerRecord<Object, Object> capturedOutput() {
        ArgumentCaptor<ProducerRecord<Object, Object>> captor =
            ArgumentCaptor.forClass((Class) ProducerRecord.class);
        org.mockito.Mockito.verify(kafkaTemplate).send(captor.capture());
        return captor.getValue();
    }

    private String header(ProducerRecord<?, ?> record, String name) {
        Header header = record.headers().lastHeader(name);
        return header == null ? null : new String(header.value(), StandardCharsets.UTF_8);
    }

    private int intHeader(ProducerRecord<?, ?> record, String name) {
        return ByteBuffer.wrap(record.headers().lastHeader(name).value()).getInt();
    }

    private long longHeader(ProducerRecord<?, ?> record, String name) {
        return ByteBuffer.wrap(record.headers().lastHeader(name).value()).getLong();
    }

    private byte[] bytes(String value) {
        return value.getBytes(StandardCharsets.UTF_8);
    }
}
