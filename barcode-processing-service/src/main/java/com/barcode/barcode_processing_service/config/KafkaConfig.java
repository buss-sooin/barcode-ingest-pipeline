package com.barcode.barcode_processing_service.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.listener.CommonErrorHandler;
import org.springframework.kafka.listener.ConsumerRecordRecoverer;
import org.springframework.kafka.listener.DeadLetterPublishingRecoverer;
import org.springframework.kafka.listener.DefaultErrorHandler;
import org.springframework.util.backoff.FixedBackOff;

import io.micrometer.core.instrument.MeterRegistry;

/**
 * CommonErrorHandler 타입 빈을 등록하면 Spring Boot 자동구성이 기본
 * ConcurrentKafkaListenerContainerFactory에 자동으로 연결한다(TECH-NOTES 참고).
 * 별도 팩토리 빈이나 @KafkaListener(containerFactory=...) 지정이 필요 없다.
 *
 * 이 서비스에서 실제로 발생하는 예외는 전부 Redis 호출 실패(일시적)뿐이라
 * 커스텀 비재시도 예외 분류는 넣지 않는다. Kafka 기본 비재시도 목록
 * (DeserializationException 등)이 유일하게 실재하는 비재시도 케이스를 이미 커버한다.
 */
@Configuration
public class KafkaConfig {

    @Bean
    public CommonErrorHandler errorHandler(KafkaTemplate<Object, Object> kafkaTemplate, MeterRegistry meterRegistry) {
        DeadLetterPublishingRecoverer publisher = new DeadLetterPublishingRecoverer(kafkaTemplate);
        ConsumerRecordRecoverer countingRecoverer = (record, exception) -> {
            meterRegistry.counter("barcode.processing.dlt.sent").increment();
            publisher.accept(record, exception);
        };
        return new DefaultErrorHandler(countingRecoverer, new FixedBackOff(2000L, 3L));
    }
}
