package com.barcode.barcode_processing_service.service;

import static org.assertj.core.api.Assertions.assertThat;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import org.apache.kafka.clients.consumer.Consumer;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.core.DefaultKafkaConsumerFactory;
import org.springframework.kafka.core.DefaultKafkaProducerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.KafkaHeaders;
import org.springframework.kafka.support.serializer.JsonSerializer;
import org.springframework.kafka.support.serializer.JsonDeserializer;
import org.springframework.kafka.test.EmbeddedKafkaBroker;
import org.springframework.kafka.test.context.EmbeddedKafka;
import org.springframework.kafka.test.utils.KafkaTestUtils;
import org.springframework.test.context.junit.jupiter.SpringJUnitConfig;

import com.barcode.barcode_processing_service.dto.BarcodeEvent;
import com.barcode.barcode_processing_service.recovery.DltHeaders;
import com.barcode.barcode_processing_service.recovery.FailureCategory;

@SpringJUnitConfig(DltDispositionKafkaIntegrationTest.TestConfiguration.class)
@EmbeddedKafka(partitions = 1, topics = {
    "bip-replay-dlt-input",
    "bip-quarantine-dlt-input",
    "bip-replay-output",
    "bip-quarantine-output"
})
class DltDispositionKafkaIntegrationTest {

    @Configuration
    static class TestConfiguration {
    }

    @Autowired
    private EmbeddedKafkaBroker broker;

    private DefaultKafkaProducerFactory<Object, Object> producerFactory;
    private KafkaTemplate<Object, Object> kafkaTemplate;
    private DltDispositionService service;

    @BeforeEach
    void setUp() {
        Map<String, Object> producerProperties =
            new HashMap<>(KafkaTestUtils.producerProps(broker.getBrokersAsString()));
        producerProperties.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        producerProperties.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, JsonSerializer.class);
        producerProperties.put(JsonSerializer.ADD_TYPE_INFO_HEADERS, false);
        producerFactory = new DefaultKafkaProducerFactory<>(producerProperties);
        kafkaTemplate = new KafkaTemplate<>(producerFactory);
        service = new DltDispositionService(
            kafkaTemplate,
            "bip-replay-output",
            "bip-quarantine-output",
            1,
            Duration.ofSeconds(10));
    }

    @AfterEach
    void tearDown() {
        producerFactory.destroy();
    }

    @Test
    void transientDltRecordIsPublishedToReplayTopic() {
        try (Consumer<String, String> consumer = outputConsumer("bip-replay-output")) {
            String groupId = "disposition-replay-" + UUID.randomUUID();
            publishDltRecord("bip-replay-dlt-input", FailureCategory.TRANSIENT_REDIS, null);
            runDisposition("bip-replay-dlt-input", groupId);

            ConsumerRecord<String, String> output = KafkaTestUtils.getSingleRecord(
                consumer, "bip-replay-output", Duration.ofSeconds(10));

            assertThat(output.key()).isEqualTo("device-1");
            assertThat(output.value()).contains("\"barcode\":\"barcode-1\"");
            assertThat(textHeader(output, DltHeaders.REPLAY_COUNT)).isEqualTo("1");
            assertThat(textHeader(output, KafkaHeaders.DLT_ORIGINAL_TOPIC))
                .isEqualTo("barcode-events");
            assertCommitted(groupId, "bip-replay-dlt-input", 1L);
        }
    }

    @Test
    void unknownDltRecordIsPublishedToQuarantineTopic() {
        try (Consumer<String, String> consumer = outputConsumer("bip-quarantine-output")) {
            String groupId = "disposition-quarantine-" + UUID.randomUUID();
            publishDltRecord("bip-quarantine-dlt-input", FailureCategory.UNKNOWN, null);
            runDisposition("bip-quarantine-dlt-input", groupId);

            ConsumerRecord<String, String> output = KafkaTestUtils.getSingleRecord(
                consumer, "bip-quarantine-output", Duration.ofSeconds(10));

            assertThat(output.key()).isEqualTo("device-1");
            assertThat(output.value()).contains("\"deviceId\":\"device-1\"");
            assertThat(textHeader(output, DltHeaders.QUARANTINE_REASON))
                .isEqualTo("UNKNOWN_FAILURE");
            assertThat(textHeader(output, DltHeaders.SOURCE_DLT_TOPIC))
                .isEqualTo("bip-quarantine-dlt-input");
            assertThat(textHeader(output, DltHeaders.SOURCE_DLT_PARTITION)).isEqualTo("0");
            assertThat(textHeader(output, DltHeaders.SOURCE_DLT_OFFSET)).isEqualTo("0");
            assertCommitted(groupId, "bip-quarantine-dlt-input", 1L);
        }
    }

    private void publishDltRecord(
        String inputTopic,
        FailureCategory category,
        String replayCount
    ) {
        ConsumerRecord<String, BarcodeEvent> source = dltRecord(category, replayCount);
        ProducerRecord<Object, Object> input = new ProducerRecord<>(
            inputTopic, 0, source.key(), source.value(), source.headers());
        kafkaTemplate.send(input).join();
    }

    private void runDisposition(String inputTopic, String groupId) {
        DltDispositionRunner runner = new DltDispositionRunner(
            dispositionConsumerFactory(groupId),
            service,
            inputTopic,
            groupId,
            Duration.ofSeconds(10),
            Duration.ofMillis(100));
        runner.run(null);
    }

    private DefaultKafkaConsumerFactory<Object, Object> dispositionConsumerFactory(String groupId) {
        Map<String, Object> properties = KafkaTestUtils.consumerProps(
            broker.getBrokersAsString(), groupId, "false");
        properties.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);
        properties.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, JsonDeserializer.class);
        properties.put(JsonDeserializer.TRUSTED_PACKAGES, "*");
        properties.put(JsonDeserializer.VALUE_DEFAULT_TYPE, BarcodeEvent.class.getName());
        properties.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        properties.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, false);
        return new DefaultKafkaConsumerFactory<>(properties);
    }

    private void assertCommitted(String groupId, String topic, long expectedOffset) {
        try (Consumer<Object, Object> consumer =
                 dispositionConsumerFactory(groupId).createConsumer(groupId)) {
            TopicPartition partition = new TopicPartition(topic, 0);
            assertThat(consumer.committed(Set.of(partition)).get(partition).offset())
                .isEqualTo(expectedOffset);
        }
    }

    private Consumer<String, String> outputConsumer(String topic) {
        Map<String, Object> properties = KafkaTestUtils.consumerProps(
            broker.getBrokersAsString(), "test-" + UUID.randomUUID(), "false");
        properties.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        Consumer<String, String> consumer = new DefaultKafkaConsumerFactory<>(
            properties, new StringDeserializer(), new StringDeserializer()).createConsumer();
        broker.consumeFromAnEmbeddedTopic(consumer, topic);
        return consumer;
    }

    private ConsumerRecord<String, BarcodeEvent> dltRecord(
        FailureCategory category,
        String replayCount
    ) {
        ConsumerRecord<String, BarcodeEvent> record = new ConsumerRecord<>(
            "barcode-events-dlt",
            0,
            5L,
            "device-1",
            new BarcodeEvent("barcode-1", 123L, "device-1"));
        record.headers().add(DltHeaders.FAILURE_CATEGORY, bytes(category.name()));
        record.headers().add(DltHeaders.FIRST_FAILURE_AT, bytes("2026-09-09T00:00:00Z"));
        record.headers().add(KafkaHeaders.DLT_ORIGINAL_TOPIC, bytes("barcode-events"));
        record.headers().add(KafkaHeaders.DLT_ORIGINAL_PARTITION,
            ByteBuffer.allocate(Integer.BYTES).putInt(0).array());
        record.headers().add(KafkaHeaders.DLT_ORIGINAL_OFFSET,
            ByteBuffer.allocate(Long.BYTES).putLong(1L).array());
        if (replayCount != null) {
            record.headers().add(DltHeaders.REPLAY_COUNT, bytes(replayCount));
        }
        return record;
    }

    private String textHeader(ConsumerRecord<?, ?> record, String name) {
        return new String(record.headers().lastHeader(name).value(), StandardCharsets.UTF_8);
    }

    private byte[] bytes(String value) {
        return value.getBytes(StandardCharsets.UTF_8);
    }
}
