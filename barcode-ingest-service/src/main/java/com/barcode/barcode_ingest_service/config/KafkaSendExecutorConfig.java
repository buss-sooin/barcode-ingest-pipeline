package com.barcode.barcode_ingest_service.config;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class KafkaSendExecutorConfig {

    /**
     * 배치 요청에서 건별 Kafka 발행을 동시에 실행하기 위한 실행기. 메타데이터가 아직
     * 캐시되지 않은 상태에서는 KafkaTemplate.send() 자체가 max.block.ms까지 호출 스레드를
     * 블로킹할 수 있어(공식 문서 확인, TECH-NOTES 참고), 건별로 순차 호출하면 대기 시간이
     * 건수만큼 곱해진다. 가상 스레드에 하나씩 맡겨 동시에 블로킹시키면 전체 대기는 건수와
     * 무관하게 max.block.ms 수준으로 유지된다.
     */
    @Bean
    public ExecutorService kafkaSendExecutor() {
        return Executors.newVirtualThreadPerTaskExecutor();
    }
}
