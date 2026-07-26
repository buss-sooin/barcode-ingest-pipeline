package com.barcode.barcode_processing_service.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.io.ClassPathResource;
import org.springframework.data.redis.connection.ReactiveRedisConnectionFactory;
import org.springframework.data.redis.core.ReactiveRedisTemplate;
import org.springframework.data.redis.core.script.RedisScript;
import org.springframework.data.redis.serializer.RedisSerializationContext;
import org.springframework.data.redis.serializer.StringRedisSerializer;

@Configuration
public class RedisConfig {

    @Bean
    public ReactiveRedisTemplate<String, String> reactiveRedisTemplate(
        ReactiveRedisConnectionFactory connectionFactory) {

        StringRedisSerializer serializer = new StringRedisSerializer();

        RedisSerializationContext<String, String> serializationContext =
            RedisSerializationContext.<String, String>newSerializationContext()
                .key(serializer)
                .value(serializer)
                .hashKey(serializer)
                .hashValue(serializer)
                .build();

        return new ReactiveRedisTemplate<>(connectionFactory, serializationContext);
    }

    /**
     * 중복 체크 + XADD + 표시를 한 번에 원자 실행하는 스크립트. 클라이언트가 두 번의
     * Redis 왕복으로 나누면 그 사이 창에서 유실 또는 중복이 생긴다(FIX-PLAN 항목 5 참고).
     */
    @Bean
    public RedisScript<Long> dedupeAndPublishScript() {
        return RedisScript.of(new ClassPathResource("scripts/dedupe-and-publish.lua"), Long.class);
    }
}
