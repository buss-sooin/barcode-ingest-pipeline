package com.barcode.barcode_processing_service.recovery;

import java.nio.charset.StandardCharsets;
import java.time.Instant;

import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.common.header.Headers;
import org.apache.kafka.common.header.internals.RecordHeader;
import org.apache.kafka.common.header.internals.RecordHeaders;
import org.springframework.kafka.listener.DeadLetterPublishingRecoverer.SingleRecordHeader;
import org.springframework.stereotype.Component;

import lombok.RequiredArgsConstructor;

@Component
@RequiredArgsConstructor
public class DltFailureHeaders {

    private final DltFailureClassifier failureClassifier;

    public Headers create(ConsumerRecord<?, ?> record, Exception failure) {
        RecordHeaders headers = new RecordHeaders();
        FailureCategory category = failureClassifier.classify(failure);

        // SingleRecordHeader는 replay record에 남은 이전 분류를 현재 실패 분류로 교체한다.
        headers.add(new SingleRecordHeader(
            DltHeaders.FAILURE_CATEGORY,
            category.name().getBytes(StandardCharsets.UTF_8)));

        if (record.headers().lastHeader(DltHeaders.FIRST_FAILURE_AT) == null) {
            headers.add(new RecordHeader(
                DltHeaders.FIRST_FAILURE_AT,
                Instant.now().toString().getBytes(StandardCharsets.UTF_8)));
        }
        return headers;
    }
}
