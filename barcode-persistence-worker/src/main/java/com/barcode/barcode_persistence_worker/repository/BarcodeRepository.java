package com.barcode.barcode_persistence_worker.repository;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import com.barcode.barcode_persistence_worker.entity.BarcodeEntity;

@Repository
public interface BarcodeRepository extends JpaRepository<BarcodeEntity, Long> {
    boolean existsByInternalBarcodeId(String internalBarcodeId);
}
