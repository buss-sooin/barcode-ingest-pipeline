package com.barcode.barcode_persistence_worker.repository;

import java.util.List;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import com.barcode.barcode_persistence_worker.entity.BarcodeEntity;

@Repository
public interface BarcodeRepository extends JpaRepository<BarcodeEntity, Long>, BarcodeRepositoryCustom {
    boolean existsByInternalBarcodeId(String internalBarcodeId);

    @Query("SELECT b.internalBarcodeId FROM BarcodeEntity b WHERE b.internalBarcodeId IN :ids")
    List<String> findExistingInternalBarcodeIds(@Param("ids") List<String> ids);

    @Query("SELECT b.originalBarcode FROM BarcodeEntity b WHERE b.originalBarcode IN :originalBarcodes")
    List<String> findExistingOriginalBarcodes(@Param("originalBarcodes") List<String> originalBarcodes);
}
