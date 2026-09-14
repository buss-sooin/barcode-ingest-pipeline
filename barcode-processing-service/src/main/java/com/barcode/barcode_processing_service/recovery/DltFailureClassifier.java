package com.barcode.barcode_processing_service.recovery;

import org.springframework.dao.QueryTimeoutException;
import org.springframework.data.redis.RedisConnectionFailureException;
import org.springframework.stereotype.Component;

import com.barcode.barcode_processing_service.exception.PermanentEventValidationException;

@Component
public class DltFailureClassifier {

    public FailureCategory classify(Throwable failure) {
        if (contains(failure, PermanentEventValidationException.class)) {
            return FailureCategory.PERMANENT_VALIDATION;
        }
        if (contains(failure, RedisConnectionFailureException.class)
            || contains(failure, QueryTimeoutException.class)) {
            return FailureCategory.TRANSIENT_REDIS;
        }
        return FailureCategory.UNKNOWN;
    }

    private boolean contains(Throwable failure, Class<? extends Throwable> type) {
        Throwable current = failure;
        while (current != null) {
            if (type.isInstance(current)) {
                return true;
            }
            current = current.getCause();
        }
        return false;
    }
}
