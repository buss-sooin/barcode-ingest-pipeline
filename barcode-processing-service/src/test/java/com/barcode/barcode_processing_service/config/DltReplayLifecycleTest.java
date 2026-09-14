package com.barcode.barcode_processing_service.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.stream.StreamSupport;

import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.PartitionInfo;
import org.apache.kafka.common.header.Header;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.data.redis.RedisConnectionFailureException;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.listener.DeadLetterPublishingRecoverer;
import org.springframework.kafka.support.KafkaHeaders;

import com.barcode.barcode_processing_service.dto.BarcodeEvent;
import com.barcode.barcode_processing_service.recovery.DltFailureClassifier;
import com.barcode.barcode_processing_service.recovery.DltFailureHeaders;
import com.barcode.barcode_processing_service.recovery.DltHeaders;
import com.barcode.barcode_processing_service.recovery.FailureCategory;
import com.barcode.barcode_processing_service.service.DltDispositionService;

class DltReplayLifecycleTest {

    @SuppressWarnings({"rawtypes", "unchecked"})
    @Test
    void replayFailureReentersDltWithGenerationOneAndRootIdentity() {
        KafkaTemplate<Object, Object> replayTemplate = mock(KafkaTemplate.class);
        when(replayTemplate.send(any(ProducerRecord.class)))
            .thenReturn(CompletableFuture.completedFuture(null));
        DltDispositionService dispositionService = new DltDispositionService(
            replayTemplate, "barcode-events", "barcode-events-quarantine", 1, Duration.ofSeconds(1));

        ConsumerRecord<String, BarcodeEvent> firstDlt = firstDltRecord();
        dispositionService.dispose(firstDlt);
        ArgumentCaptor<ProducerRecord<Object, Object>> replayCaptor =
            ArgumentCaptor.forClass((Class) ProducerRecord.class);
        verify(replayTemplate).send(replayCaptor.capture());
        ProducerRecord<Object, Object> replay = replayCaptor.getValue();

        ConsumerRecord<Object, Object> listenerFailure = new ConsumerRecord<>(
            replay.topic(), 0, 200L, replay.key(), replay.value());
        replay.headers().forEach(listenerFailure.headers()::add);

        KafkaTemplate<Object, Object> dltTemplate = mock(KafkaTemplate.class);
        when(dltTemplate.partitionsFor("barcode-events-dlt")).thenReturn(List.of(
            new PartitionInfo("barcode-events-dlt", 0, null, null, null)));
        when(dltTemplate.send(any(ProducerRecord.class)))
            .thenReturn(CompletableFuture.completedFuture(null));
        KafkaConfig kafkaConfig = new KafkaConfig();
        DeadLetterPublishingRecoverer publisher = kafkaConfig.dltPublisher(
            dltTemplate, new DltFailureHeaders(new DltFailureClassifier()));

        publisher.accept(listenerFailure, new RedisConnectionFailureException("redis unavailable"));

        ArgumentCaptor<ProducerRecord<Object, Object>> secondDltCaptor =
            ArgumentCaptor.forClass((Class) ProducerRecord.class);
        verify(dltTemplate).send(secondDltCaptor.capture());
        ProducerRecord<Object, Object> secondDlt = secondDltCaptor.getValue();

        assertThat(textHeader(secondDlt, DltHeaders.REPLAY_COUNT)).isEqualTo("1");
        assertThat(textHeader(secondDlt, DltHeaders.FAILURE_CATEGORY))
            .isEqualTo(FailureCategory.TRANSIENT_REDIS.name());
        assertThat(textHeader(secondDlt, KafkaHeaders.DLT_ORIGINAL_TOPIC))
            .isEqualTo("barcode-events");
        assertThat(intHeader(secondDlt, KafkaHeaders.DLT_ORIGINAL_PARTITION)).isEqualTo(7);
        assertThat(longHeader(secondDlt, KafkaHeaders.DLT_ORIGINAL_OFFSET)).isEqualTo(101L);
        assertThat(StreamSupport.stream(
            secondDlt.headers().headers(KafkaHeaders.DLT_ORIGINAL_TOPIC).spliterator(), false))
            .hasSize(1);
    }

    private ConsumerRecord<String, BarcodeEvent> firstDltRecord() {
        ConsumerRecord<String, BarcodeEvent> record = new ConsumerRecord<>(
            "barcode-events-dlt",
            2,
            41L,
            "device-1",
            new BarcodeEvent("barcode-1", 123L, "device-1"));
        record.headers().add(DltHeaders.FAILURE_CATEGORY, bytes("TRANSIENT_REDIS"));
        record.headers().add(DltHeaders.FIRST_FAILURE_AT, bytes("2026-09-09T00:00:00Z"));
        record.headers().add(KafkaHeaders.DLT_ORIGINAL_TOPIC, bytes("barcode-events"));
        record.headers().add(KafkaHeaders.DLT_ORIGINAL_PARTITION,
            ByteBuffer.allocate(Integer.BYTES).putInt(7).array());
        record.headers().add(KafkaHeaders.DLT_ORIGINAL_OFFSET,
            ByteBuffer.allocate(Long.BYTES).putLong(101L).array());
        return record;
    }

    private String textHeader(ProducerRecord<?, ?> record, String name) {
        Header header = record.headers().lastHeader(name);
        return new String(header.value(), StandardCharsets.UTF_8);
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
