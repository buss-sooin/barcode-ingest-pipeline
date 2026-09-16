package com.barcode.barcode_processing_service.recovery;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.data.redis.RedisConnectionFailureException;

import com.barcode.barcode_processing_service.exception.PermanentEventValidationException;

class DltFailureClassifierTest {

    private final DltFailureClassifier classifier = new DltFailureClassifier();

    @Test
    void classifiesRedisConnectionFailureAsTransient() {
        RuntimeException wrapped = new RuntimeException(
            new RedisConnectionFailureException("redis unavailable"));

        assertThat(classifier.classify(wrapped)).isEqualTo(FailureCategory.TRANSIENT_REDIS);
    }

    @Test
    void classifiesPermanentValidationFailure() {
        assertThat(classifier.classify(
            new PermanentEventValidationException("invalid deviceId")))
            .isEqualTo(FailureCategory.PERMANENT_VALIDATION);
    }

    @Test
    void classifiesUnrecognizedFailureAsUnknown() {
        assertThat(classifier.classify(new IllegalStateException("other failure")))
            .isEqualTo(FailureCategory.UNKNOWN);
    }
}
