package com.barcode.barcode_scanner_service.config;

import java.util.concurrent.ThreadPoolExecutor;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;

/**
 * ApiGatewayTransmitter.transmitBatch 전용 실행기를 등록한다. 별도로 등록하지
 * 않으면 Spring은 @Async 메서드에 기본 실행기(SimpleAsyncTaskExecutor)를 쓰는데,
 * 이 실행기는 호출마다 새 스레드를 만들고 동시 개수를 제한하지 않는다 — 전송
 * 요청이 몰리면 스레드가 무제한으로 생겨난다.
 *
 * 이 실행기는 동시 실행 개수를 ingest로 가는 HTTP 커넥션 풀의 최대치(50,
 * RestClientConfig)에 맞춰 제한한다. 풀과 대기열이 다 차면 새 스레드를 만드는
 * 대신 호출한 스레드가 그 작업을 직접 실행하게 해서(CallerRunsPolicy), 부하가
 * 상위 단계(배치를 만드는 쪽)로 자연스럽게 전파되도록 한다.
 */
@Configuration
public class AsyncConfig {

    @Bean("transmitExecutor")
    public ThreadPoolTaskExecutor transmitExecutor() {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setCorePoolSize(20);
        executor.setMaxPoolSize(50);
        executor.setQueueCapacity(50);
        executor.setThreadNamePrefix("transmit-");
        executor.setRejectedExecutionHandler(new ThreadPoolExecutor.CallerRunsPolicy());
        executor.initialize();
        return executor;
    }
}
