package com.barcode.barcode_processing_service.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.listener.CommonErrorHandler;
import org.springframework.kafka.listener.ConsumerRecordRecoverer;
import org.springframework.kafka.listener.DeadLetterPublishingRecoverer;
import org.springframework.kafka.listener.DefaultErrorHandler;
import org.springframework.util.backoff.FixedBackOff;

import com.barcode.barcode_processing_service.exception.PermanentEventValidationException;
import com.barcode.barcode_processing_service.recovery.DltFailureHeaders;

import io.micrometer.core.instrument.MeterRegistry;

/**
 * CommonErrorHandler 타입 빈을 등록하면 Spring Boot 자동구성이 기본
 * ConcurrentKafkaListenerContainerFactory에 자동으로 연결한다(TECH-NOTES 참고).
 * 별도 팩토리 빈이나 @KafkaListener(containerFactory=...) 지정이 필요 없다.
 *
 * Redis 연결 실패는 기존 FixedBackOff로 재시도하고, 생산 계약을 위반한 이벤트는
 * 재시도 없이 DLT로 보낸다.
 */
@Configuration
public class KafkaConfig {

    @Bean
    public CommonErrorHandler errorHandler(
        KafkaTemplate<Object, Object> kafkaTemplate,
        MeterRegistry meterRegistry,
        DltFailureHeaders failureHeaders
    ) {
        DeadLetterPublishingRecoverer publisher = dltPublisher(kafkaTemplate, failureHeaders);

        ConsumerRecordRecoverer countingRecoverer = (record, exception) -> {
            publisher.accept(record, exception);
            meterRegistry.counter("barcode.processing.dlt.sent").increment();
        };
        DefaultErrorHandler handler =
            new DefaultErrorHandler(countingRecoverer, new FixedBackOff(2000L, 3L));
        handler.addNotRetryableExceptions(PermanentEventValidationException.class);
        return handler;
    }

    DeadLetterPublishingRecoverer dltPublisher(
        KafkaTemplate<Object, Object> kafkaTemplate,
        DltFailureHeaders failureHeaders
    ) {
        DeadLetterPublishingRecoverer publisher = new DeadLetterPublishingRecoverer(kafkaTemplate);
        publisher.setAppendOriginalHeaders(false);
        publisher.setHeadersFunction(failureHeaders::create);
        publisher.setFailIfSendResultIsError(true);
        return publisher;
    }
}
