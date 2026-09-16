package com.barcode.barcode_persistence_worker.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyCollection;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.dao.TransientDataAccessResourceException;
import org.springframework.data.domain.Range;
import org.springframework.data.redis.connection.RedisStreamCommands.XAddOptions;
import org.springframework.data.redis.connection.stream.Consumer;
import org.springframework.data.redis.connection.stream.MapRecord;
import org.springframework.data.redis.connection.stream.PendingMessage;
import org.springframework.data.redis.connection.stream.PendingMessages;
import org.springframework.data.redis.connection.stream.PendingMessagesSummary;
import org.springframework.data.redis.connection.stream.RecordId;
import org.springframework.data.redis.connection.stream.StreamOffset;
import org.springframework.data.redis.connection.stream.StreamReadOptions;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.core.StreamOperations;
import org.springframework.test.util.ReflectionTestUtils;

import com.barcode.barcode_persistence_worker.entity.DeviceCenterMappingEntity;
import com.barcode.barcode_persistence_worker.repository.BarcodeRepository;
import com.barcode.barcode_persistence_worker.repository.DeviceCenterMappingRepository;

import io.micrometer.core.instrument.simple.SimpleMeterRegistry;

@ExtendWith(MockitoExtension.class)
class RedisStreamConsumerTest {

    private static final String STREAM = "barcode:stream";
    private static final String GROUP = "barcode-persistence-group";
    private static final String DLQ = "barcode:stream:dlq";
    private static final Duration RECLAIM_IDLE = Duration.ofMinutes(5);

    @Mock
    private RedisTemplate<String, String> redisTemplate;

    @Mock
    private StreamOperations<String, Object, Object> streamOperations;

    @Mock
    private BarcodeRepository barcodeRepository;

    @Mock
    private DeviceCenterMappingRepository deviceMappingRepository;

    private RedisStreamConsumer consumer;

    @BeforeEach
    void setUp() {
        when(redisTemplate.<Object, Object>opsForStream()).thenReturn(streamOperations);
        consumer = newConsumer("worker-1");
    }

    @Test
    void doesNothingWhenNoPendingEntryExists() {
        when(streamOperations.pending(STREAM, GROUP)).thenReturn(summary(0));

        consumer.processPendingMessages();

        verify(streamOperations, never()).pending(eq(STREAM), eq(GROUP), any(Range.class), anyLong());
        verify(streamOperations, never()).claim(
            eq(STREAM), eq(GROUP), eq("worker-1"), eq(RECLAIM_IDLE), any(RecordId[].class));
    }

    @Test
    void doesNotClaimPendingEntryBeforeIdleThreshold() {
        RecordId id = RecordId.of("1000-0");
        when(streamOperations.pending(STREAM, GROUP)).thenReturn(summary(1));
        when(streamOperations.pending(eq(STREAM), eq(GROUP), any(Range.class), eq(100L)))
            .thenReturn(page(pending(id, "worker-2", Duration.ofMinutes(4))));

        consumer.processPendingMessages();

        verify(streamOperations, never()).claim(
            eq(STREAM), eq(GROUP), eq("worker-1"), eq(RECLAIM_IDLE), any(RecordId[].class));
    }

    @Test
    void claimsExplicitEligibleIdAndAcknowledgesOnlyAfterDatabaseSuccess() {
        RecordId id = RecordId.of("1001-0");
        MapRecord<String, Object, Object> record = validRecord(id, "internal-1", "original-1");
        stubSingleEligiblePending(id, record);
        stubDeviceMapping();

        consumer.processPendingMessages();

        ArgumentCaptor<RecordId[]> claimIds = ArgumentCaptor.forClass(RecordId[].class);
        InOrder ordered = inOrder(streamOperations, barcodeRepository);
        ordered.verify(streamOperations).claim(
            eq(STREAM), eq(GROUP), eq("worker-1"), eq(RECLAIM_IDLE), claimIds.capture());
        ordered.verify(barcodeRepository).batchInsert(any());
        ordered.verify(streamOperations).acknowledge(eq(STREAM), eq(GROUP), any(RecordId[].class));
        assertThat(claimIds.getValue()).containsExactly(id);
    }

    @Test
    void neverInvokesClaimWithEmptyIds() {
        RecordId youngId = RecordId.of("1002-0");
        when(streamOperations.pending(STREAM, GROUP)).thenReturn(summary(1));
        when(streamOperations.pending(eq(STREAM), eq(GROUP), any(Range.class), eq(100L)))
            .thenReturn(page(pending(youngId, "worker-2", Duration.ofSeconds(30))));

        consumer.processPendingMessages();

        verify(streamOperations, never()).claim(
            eq(STREAM), eq(GROUP), eq("worker-1"), eq(RECLAIM_IDLE), any(RecordId[].class));
    }

    @Test
    void paginatesBeyondOneHundredPendingEntriesWithoutSkippingEligibleIds() {
        List<PendingMessage> firstHundred = new ArrayList<>();
        for (int index = 0; index < 100; index++) {
            firstHundred.add(pending(RecordId.of("2000-" + index), "worker-1", Duration.ofMinutes(6)));
        }
        RecordId lastId = RecordId.of("2001-0");
        when(streamOperations.pending(STREAM, GROUP)).thenReturn(summary(101));
        when(streamOperations.pending(eq(STREAM), eq(GROUP), any(Range.class), eq(100L)))
            .thenReturn(page(firstHundred), page(pending(lastId, "worker-2", Duration.ofMinutes(7))));
        when(streamOperations.claim(
            eq(STREAM), eq(GROUP), eq("worker-1"), eq(RECLAIM_IDLE), any(RecordId[].class)))
            .thenReturn(List.of());

        consumer.processPendingMessages();

        ArgumentCaptor<RecordId[]> claimIds = ArgumentCaptor.forClass(RecordId[].class);
        verify(streamOperations, times(2)).claim(
            eq(STREAM), eq(GROUP), eq("worker-1"), eq(RECLAIM_IDLE), claimIds.capture());
        assertThat(claimIds.getAllValues()).allSatisfy(ids -> assertThat(ids).isNotEmpty());
        assertThat(claimIds.getAllValues().get(0)).hasSize(100);
        assertThat(claimIds.getAllValues().get(1)).containsExactly(lastId);

        ArgumentCaptor<Range<?>> ranges = ArgumentCaptor.forClass(Range.class);
        verify(streamOperations, times(2)).pending(eq(STREAM), eq(GROUP), ranges.capture(), eq(100L));
        Range<?> secondRange = ranges.getAllValues().get(1);
        assertThat(secondRange.getLowerBound().isInclusive()).isFalse();
        assertThat(secondRange.getLowerBound().getValue().orElseThrow()).isEqualTo("2000-99");
    }

    @Test
    void concurrentWorkersRelyOnAtomicMinIdleRecheckForSamePendingId() {
        RedisStreamConsumer secondConsumer = newConsumer("worker-2");
        RecordId id = RecordId.of("3000-0");
        MapRecord<String, Object, Object> record = validRecord(id, "internal-3", "original-3");
        PendingMessages page = page(pending(id, "worker-1", Duration.ofMinutes(6)));

        when(streamOperations.pending(STREAM, GROUP)).thenReturn(summary(1));
        when(streamOperations.pending(eq(STREAM), eq(GROUP), any(Range.class), eq(100L))).thenReturn(page);
        when(streamOperations.claim(
            eq(STREAM), eq(GROUP), eq("worker-1"), eq(RECLAIM_IDLE), any(RecordId[].class)))
            .thenReturn(List.of(record));
        when(streamOperations.claim(
            eq(STREAM), eq(GROUP), eq("worker-2"), eq(RECLAIM_IDLE), any(RecordId[].class)))
            .thenReturn(List.of());
        stubDeviceMapping();

        consumer.processPendingMessages();
        secondConsumer.processPendingMessages();

        verify(streamOperations).claim(
            eq(STREAM), eq(GROUP), eq("worker-1"), eq(RECLAIM_IDLE),
            eq(id));
        verify(streamOperations).claim(
            eq(STREAM), eq(GROUP), eq("worker-2"), eq(RECLAIM_IDLE),
            eq(id));
        verify(barcodeRepository, times(1)).batchInsert(any());
        verify(streamOperations, times(1)).acknowledge(eq(STREAM), eq(GROUP), any(RecordId[].class));
    }

    @Test
    void withholdsAcknowledgmentWhenDatabaseLookupFailsAfterClaim() {
        RecordId id = RecordId.of("4000-0");
        MapRecord<String, Object, Object> record = validRecord(id, "internal-4", "original-4");
        stubSingleEligiblePending(id, record);
        when(deviceMappingRepository.findByDeviceIdIn(anyCollection()))
            .thenThrow(new TransientDataAccessResourceException("mysql unavailable"));

        consumer.processPendingMessages();

        verify(streamOperations, never()).acknowledge(eq(STREAM), eq(GROUP), any(RecordId[].class));
        verify(barcodeRepository, never()).batchInsert(any());
    }

    @Test
    void normalNewMessageConsumptionStillPersistsThenAcknowledges() {
        RecordId id = RecordId.of("5000-0");
        MapRecord<String, Object, Object> record = validRecord(id, "internal-5", "original-5");
        when(streamOperations.read(
            any(Consumer.class), any(StreamReadOptions.class), any(StreamOffset[].class)))
            .thenReturn(List.of(record));
        stubDeviceMapping();

        consumer.processBatch();

        InOrder ordered = inOrder(barcodeRepository, streamOperations);
        ordered.verify(barcodeRepository).batchInsert(any());
        ordered.verify(streamOperations).acknowledge(eq(STREAM), eq(GROUP), any(RecordId[].class));
    }

    @Test
    void invalidRecordIsAcknowledgedOnlyAfterDlqAppendSucceeds() {
        RecordId id = RecordId.of("6000-0");
        MapRecord<String, Object, Object> record = validRecord(id, "internal-6", "original-6");
        when(streamOperations.read(
            any(Consumer.class), any(StreamReadOptions.class), any(StreamOffset[].class)))
            .thenReturn(List.of(record));
        when(deviceMappingRepository.findByDeviceIdIn(anyCollection())).thenReturn(List.of());
        when(streamOperations.add(
            any(MapRecord.class), any(XAddOptions.class)))
            .thenReturn(RecordId.of("9000-0"));

        consumer.processBatch();

        InOrder ordered = inOrder(streamOperations);
        ordered.verify(streamOperations).add(
            any(MapRecord.class), any(XAddOptions.class));
        ordered.verify(streamOperations).acknowledge(eq(STREAM), eq(GROUP), any(RecordId[].class));
    }

    @Test
    void dlqAppendFailureKeepsOriginalPending() {
        RecordId id = RecordId.of("6001-0");
        MapRecord<String, Object, Object> record = validRecord(id, "internal-7", "original-7");
        when(streamOperations.read(
            any(Consumer.class), any(StreamReadOptions.class), any(StreamOffset[].class)))
            .thenReturn(List.of(record));
        when(deviceMappingRepository.findByDeviceIdIn(anyCollection())).thenReturn(List.of());
        when(streamOperations.add(
            any(MapRecord.class), any(XAddOptions.class)))
            .thenThrow(new RuntimeException("redis write failed"));

        consumer.processBatch();

        verify(streamOperations, never()).acknowledge(eq(STREAM), eq(GROUP), any(RecordId[].class));
    }

    private RedisStreamConsumer newConsumer(String name) {
        RedisStreamConsumer instance = new RedisStreamConsumer(
            redisTemplate,
            barcodeRepository,
            deviceMappingRepository,
            new SimpleMeterRegistry()
        );
        ReflectionTestUtils.setField(instance, "streamKey", STREAM);
        ReflectionTestUtils.setField(instance, "consumerGroup", GROUP);
        ReflectionTestUtils.setField(instance, "consumerName", name);
        ReflectionTestUtils.setField(instance, "batchSize", 100);
        ReflectionTestUtils.setField(instance, "blockTime", 5000L);
        ReflectionTestUtils.setField(instance, "dlqStreamKey", DLQ);
        ReflectionTestUtils.setField(instance, "dlqMaxLen", 10000L);
        return instance;
    }

    private void stubSingleEligiblePending(
        RecordId id,
        MapRecord<String, Object, Object> claimedRecord
    ) {
        when(streamOperations.pending(STREAM, GROUP)).thenReturn(summary(1));
        when(streamOperations.pending(eq(STREAM), eq(GROUP), any(Range.class), eq(100L)))
            .thenReturn(page(pending(id, "worker-2", Duration.ofMinutes(6))));
        when(streamOperations.claim(
            eq(STREAM), eq(GROUP), eq("worker-1"), eq(RECLAIM_IDLE), any(RecordId[].class)))
            .thenReturn(List.of(claimedRecord));
    }

    private void stubDeviceMapping() {
        when(deviceMappingRepository.findByDeviceIdIn(anyCollection())).thenReturn(List.of(
            DeviceCenterMappingEntity.builder()
                .deviceId("SEOUL-CENTER-PC-001")
                .centerId("SEOUL-CENTER")
                .build()
        ));
    }

    private PendingMessagesSummary summary(long count) {
        return new PendingMessagesSummary(GROUP, count, Range.unbounded(), Map.of());
    }

    private PendingMessages page(PendingMessage... messages) {
        return page(List.of(messages));
    }

    private PendingMessages page(List<PendingMessage> messages) {
        return new PendingMessages(GROUP, Range.unbounded(), messages);
    }

    private PendingMessage pending(RecordId id, String owner, Duration idle) {
        return new PendingMessage(id, Consumer.from(GROUP, owner), idle, 1);
    }

    private MapRecord<String, Object, Object> validRecord(
        RecordId id,
        String internalBarcodeId,
        String originalBarcode
    ) {
        Map<Object, Object> values = Map.of(
            "internalBarcodeId", internalBarcodeId,
            "originalBarcode", originalBarcode,
            "deviceId", "SEOUL-CENTER-PC-001",
            "scanTime", "1788512400000",
            "processedTime", "1788512400100"
        );
        return MapRecord.create(STREAM, values).withId(id);
    }
}
