package com.barcode.barcode_processing_service.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;

import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.data.redis.core.ReactiveRedisTemplate;
import org.springframework.data.redis.core.script.RedisScript;

import com.barcode.barcode_processing_service.dto.BarcodeEvent;
import com.barcode.barcode_processing_service.exception.PermanentEventValidationException;

class BarcodeEventConsumerTest {

    @Test
    void dltDispositionProfileExcludesNormalBarcodeEventsListener() {
        try (AnnotationConfigApplicationContext context =
                 new AnnotationConfigApplicationContext()) {
            context.getEnvironment().setActiveProfiles("dlt-disposition");
            context.register(BarcodeEventConsumer.class);
            context.refresh();

            assertThat(context.getBeansOfType(BarcodeEventConsumer.class)).isEmpty();
        }
    }

    @SuppressWarnings("unchecked")
    @Test
    void blankDeviceIdFailsBeforeRedisHandoff() {
        BarcodeConverter converter = mock(BarcodeConverter.class);
        ReactiveRedisTemplate<String, String> redisTemplate = mock(ReactiveRedisTemplate.class);
        RedisScript<Long> script = mock(RedisScript.class);
        BarcodeEventConsumer consumer = new BarcodeEventConsumer(converter, redisTemplate, script);

        assertThatThrownBy(() -> consumer.consumeBarcodeEvent(
            new BarcodeEvent("barcode", 1L, "  "), 0, 1L, "key"))
            .isInstanceOf(PermanentEventValidationException.class)
            .hasMessage("deviceId must not be null or blank");

        verifyNoInteractions(converter, redisTemplate, script);
    }
}
