package com.barcode.barcode_processing_service.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

import org.junit.jupiter.api.Test;
import org.springframework.classify.BinaryExceptionClassifier;
import org.springframework.data.redis.RedisConnectionFailureException;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.listener.DefaultErrorHandler;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.util.backoff.FixedBackOff;

import com.barcode.barcode_processing_service.exception.PermanentEventValidationException;
import com.barcode.barcode_processing_service.recovery.DltFailureClassifier;
import com.barcode.barcode_processing_service.recovery.DltFailureHeaders;

import io.micrometer.core.instrument.simple.SimpleMeterRegistry;

class KafkaConfigTest {

    @SuppressWarnings("unchecked")
    @Test
    void preservesSourceRetryBackoffAndMakesPermanentValidationNonRetryable() {
        KafkaConfig config = new KafkaConfig();
        DefaultErrorHandler handler = (DefaultErrorHandler) config.errorHandler(
            mock(KafkaTemplate.class),
            new SimpleMeterRegistry(),
            new DltFailureHeaders(new DltFailureClassifier()));

        Object tracker = ReflectionTestUtils.getField(handler, "failureTracker");
        FixedBackOff backOff = (FixedBackOff) ReflectionTestUtils.getField(tracker, "backOff");
        BinaryExceptionClassifier classifier =
            (BinaryExceptionClassifier) ReflectionTestUtils.getField(handler, "classifier");

        assertThat(backOff.getInterval()).isEqualTo(2000L);
        assertThat(backOff.getMaxAttempts()).isEqualTo(3L);
        assertThat(classifier.classify(
            new PermanentEventValidationException("invalid"))).isFalse();
        assertThat(classifier.classify(
            new RedisConnectionFailureException("unavailable"))).isTrue();
    }
}
