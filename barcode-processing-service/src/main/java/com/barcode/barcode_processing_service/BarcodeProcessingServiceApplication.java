package com.barcode.barcode_processing_service;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.autoconfigure.data.redis.RedisReactiveAutoConfiguration;

@SpringBootApplication(exclude = {RedisReactiveAutoConfiguration.class})
public class BarcodeProcessingServiceApplication {

	public static void main(String[] args) {
		SpringApplication.run(BarcodeProcessingServiceApplication.class, args);
	}

}
