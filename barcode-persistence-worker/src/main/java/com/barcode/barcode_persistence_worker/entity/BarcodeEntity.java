package com.barcode.barcode_persistence_worker.entity;

import java.time.Instant;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Index;
import jakarta.persistence.Table;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Getter;
import lombok.NoArgsConstructor;

@Entity
@Table(name = "barcodes", indexes = {
    @Index(name = "idx_internal_barcode_id", columnList = "internalBarcodeId", unique = true),
    @Index(name = "idx_original_barcode", columnList = "originalBarcode"),
    @Index(name = "idx_center_id", columnList = "centerId")
})
@Getter
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class BarcodeEntity {
    
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;
    
    @Column(nullable = false, unique = true, length = 100)
    private String internalBarcodeId;
    
    @Column(nullable = false, length = 100)
    private String originalBarcode;
    
    @Column(nullable = false)
    private String centerId;

    @Column(nullable = false, length = 50)
    private String deviceId;
    
    @Column(nullable = false)
    private Instant scanTime;
    
    @Column(nullable = false)
    private Instant processedTime;
    
    @Column(nullable = false)
    private Instant savedTime;
}

