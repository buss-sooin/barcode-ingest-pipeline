package com.barcode.barcode_persistence_worker.repository;

import java.util.Optional;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import com.barcode.barcode_persistence_worker.entity.DeviceCenterMappingEntity;

@Repository
public interface DeviceCenterMappingRepository extends JpaRepository<DeviceCenterMappingEntity, Long> {
    
    Optional<DeviceCenterMappingEntity> findByDeviceId(String deviceId);
    
}
