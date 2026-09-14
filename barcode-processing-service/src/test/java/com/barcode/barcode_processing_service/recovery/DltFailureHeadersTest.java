package com.barcode.barcode_processing_service.recovery;

import static org.assertj.core.api.Assertions.assertThat;

import java.nio.charset.StandardCharsets;

import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.junit.jupiter.api.Test;

import com.barcode.barcode_processing_service.exception.PermanentEventValidationException;

class DltFailureHeadersTest {

    @Test
    void currentFailureClassificationReplacesStaleReplayMetadata() {
        ConsumerRecord<String, String> replayed =
            new ConsumerRecord<>("barcode-events", 0, 10L, "device", "value");
        replayed.headers().add(
            DltHeaders.FAILURE_CATEGORY,
            FailureCategory.TRANSIENT_REDIS.name().getBytes(StandardCharsets.UTF_8));

        DltFailureHeaders factory =
            new DltFailureHeaders(new DltFailureClassifier());

        var headers = factory.create(
            replayed,
            new PermanentEventValidationException("current failure"));

        assertThat(new String(
            headers.lastHeader(DltHeaders.FAILURE_CATEGORY).value(), StandardCharsets.UTF_8))
            .isEqualTo(FailureCategory.PERMANENT_VALIDATION.name());
        assertThat(headers.lastHeader(DltHeaders.FAILURE_CATEGORY))
            .isInstanceOf(org.springframework.kafka.listener.DeadLetterPublishingRecoverer
                .SingleRecordHeader.class);
    }
}
