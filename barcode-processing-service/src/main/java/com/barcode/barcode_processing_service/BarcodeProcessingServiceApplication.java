package com.barcode.barcode_processing_service;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.autoconfigure.data.redis.RedisReactiveAutoConfiguration;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.core.env.Profiles;

@SpringBootApplication(exclude = {RedisReactiveAutoConfiguration.class})
public class BarcodeProcessingServiceApplication {

	public static void main(String[] args) {
		ConfigurableApplicationContext context =
			SpringApplication.run(BarcodeProcessingServiceApplication.class, args);
		if (context.getEnvironment().acceptsProfiles(Profiles.of("dlt-disposition"))) {
			System.exit(SpringApplication.exit(context));
		}
	}

}
