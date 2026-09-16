package com.barcode.barcode_processing_service.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import java.time.Duration;
import java.util.Map;

import org.apache.kafka.clients.consumer.Consumer;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.common.TopicPartition;
import org.junit.jupiter.api.Test;
import org.springframework.kafka.core.ConsumerFactory;

import com.barcode.barcode_processing_service.recovery.DispositionOutcome;
import com.barcode.barcode_processing_service.recovery.DispositionResult;
import com.barcode.barcode_processing_service.recovery.DltDispositionPublicationException;
import com.barcode.barcode_processing_service.recovery.FailureCategory;

class DltDispositionRunnerTest {

    @SuppressWarnings("unchecked")
    @Test
    void outputPublicationFailureDoesNotCommitDltOffset() {
        ConsumerFactory<?, ?> consumerFactory = mock(ConsumerFactory.class);
        DltDispositionService service = mock(DltDispositionService.class);
        Consumer<?, ?> consumer = mock(Consumer.class);
        ConsumerRecord<String, String> record =
            new ConsumerRecord<>("barcode-events-dlt", 0, 12L, "key", "value");
        doThrow(new DltDispositionPublicationException("failed", new RuntimeException()))
            .when(service).dispose(any());
        DltDispositionRunner runner = new DltDispositionRunner(
            consumerFactory,
            service,
            "barcode-events-dlt",
            "barcode-events-dlt-disposition",
            Duration.ofSeconds(1),
            Duration.ofMillis(10));

        assertThatThrownBy(() -> runner.processAndCommit(record, consumer))
            .isInstanceOf(DltDispositionPublicationException.class);

        verifyNoInteractions(consumer);
    }

    @SuppressWarnings("unchecked")
    @Test
    void commitFailureAfterPublicationIsNotLoggedAsSettled() {
        DltDispositionService service = mock(DltDispositionService.class);
        Consumer<?, ?> consumer = mock(Consumer.class);
        ConsumerRecord<String, String> record =
            new ConsumerRecord<>("barcode-events-dlt", 0, 12L, "key", "value");
        DispositionOutcome published = new DispositionOutcome(
            DispositionResult.REPLAYED, FailureCategory.TRANSIENT_REDIS, 1, null);
        when(service.dispose(record)).thenReturn(published);
        doThrow(new IllegalStateException("commit failed")).when(consumer).commitSync(anyMap());
        DltDispositionRunner runner = runner(service);

        assertThatThrownBy(() -> runner.processAndCommit(record, consumer))
            .isInstanceOf(IllegalStateException.class)
            .hasMessage("commit failed");

        verify(service).logSettlementFailed(
            org.mockito.ArgumentMatchers.eq(record),
            org.mockito.ArgumentMatchers.eq(published),
            any(IllegalStateException.class));
        verify(service, never()).logSettled(any(), any());
    }

    @SuppressWarnings("unchecked")
    @Test
    void frozenBoundaryExcludesRecordsAtOrBeyondSnapshotEnd() {
        DltDispositionRunner runner = runner(mock(DltDispositionService.class));
        TopicPartition partition = new TopicPartition("barcode-events-dlt", 0);
        Map<TopicPartition, Long> boundary = Map.of(partition, 5L);

        assertThat(runner.withinFrozenBacklog(
            new ConsumerRecord<>(partition.topic(), partition.partition(), 4L, "key", "value"),
            boundary)).isTrue();
        assertThat(runner.withinFrozenBacklog(
            new ConsumerRecord<>(partition.topic(), partition.partition(), 5L, "key", "value"),
            boundary)).isFalse();
    }

    @SuppressWarnings("unchecked")
    @Test
    void emptyAndMultiplePartitionBacklogsCompleteDeterministically() {
        DltDispositionRunner runner = runner(mock(DltDispositionService.class));
        Consumer<?, ?> consumer = mock(Consumer.class);
        TopicPartition first = new TopicPartition("barcode-events-dlt", 0);
        TopicPartition second = new TopicPartition("barcode-events-dlt", 1);

        assertThat(runner.backlogComplete(consumer, Map.of())).isTrue();

        when(consumer.position(first)).thenReturn(3L);
        when(consumer.position(second)).thenReturn(7L);
        assertThat(runner.backlogComplete(consumer, Map.of(first, 3L, second, 7L))).isTrue();

        when(consumer.position(second)).thenReturn(6L);
        assertThat(runner.backlogComplete(consumer, Map.of(first, 3L, second, 7L))).isFalse();
    }

    private DltDispositionRunner runner(DltDispositionService service) {
        return new DltDispositionRunner(
            mock(ConsumerFactory.class),
            service,
            "barcode-events-dlt",
            "barcode-events-dlt-disposition",
            Duration.ofSeconds(1),
            Duration.ofMillis(10));
    }
}
