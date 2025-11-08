package com.barcode.barcode_scanner_service.controller;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import lombok.extern.slf4j.Slf4j;

@Slf4j
@RestController
public class HealthCheckController {

    @GetMapping("/")
    public String checkHealth() {
        return "Barcode Service is Running on Port 8081!";
    }

}
