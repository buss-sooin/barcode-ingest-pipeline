package com.barcode.barcode_persistence_worker.entity;

import java.time.LocalDateTime;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Getter;
import lombok.NoArgsConstructor;

@Entity
@Table(name = "device_center_mapping")
@Getter
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class DeviceCenterMappingEntity {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;
    
    @Column(unique = true, nullable = false)
    private String deviceId;
    
    @Column(nullable = false)
    private String centerId;
    
    private String centerName;
    
    private LocalDateTime updatedTime;
}
