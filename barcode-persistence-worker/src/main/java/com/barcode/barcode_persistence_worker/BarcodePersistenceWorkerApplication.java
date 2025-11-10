package com.barcode.barcode_persistence_worker;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;

@EnableJpaAuditing
@SpringBootApplication
public class BarcodePersistenceWorkerApplication {

	public static void main(String[] args) {
		SpringApplication.run(BarcodePersistenceWorkerApplication.class, args);
	}

}
