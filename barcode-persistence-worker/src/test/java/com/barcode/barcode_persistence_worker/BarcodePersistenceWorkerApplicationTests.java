package com.barcode.barcode_persistence_worker;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.bean.override.mockito.MockitoBean;

import com.barcode.barcode_persistence_worker.service.RedisStreamConsumer;

@SpringBootTest(properties = {
	"spring.datasource.url=jdbc:h2:mem:barcode-worker-test;MODE=MySQL;DB_CLOSE_DELAY=-1",
	"spring.datasource.driver-class-name=org.h2.Driver",
	"spring.datasource.username=sa",
	"spring.datasource.password=",
	"spring.jpa.hibernate.ddl-auto=create-drop",
	"spring.jpa.properties.hibernate.dialect=org.hibernate.dialect.H2Dialect",
	"spring.sql.init.mode=never"
})
class BarcodePersistenceWorkerApplicationTests {

	@MockitoBean
	private RedisStreamConsumer redisStreamConsumer;

	@Test
	void contextLoads() {
	}

}
