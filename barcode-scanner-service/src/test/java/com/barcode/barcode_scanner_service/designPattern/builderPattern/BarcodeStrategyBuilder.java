package com.barcode.barcode_scanner_service.designPattern.builderPattern;

import com.barcode.barcode_scanner_service.designPattern.BarcodeType;
import com.barcode.barcode_scanner_service.designPattern.strategyPattern.barcodeStrategy.EAN13Strategy;
import com.barcode.barcode_scanner_service.designPattern.strategyPattern.barcodeStrategy.IBarcodeStrategy;
import com.barcode.barcode_scanner_service.designPattern.strategyPattern.barcodeStrategy.ITF14Strategy;
import com.barcode.barcode_scanner_service.designPattern.strategyPattern.checkDigitStrategy.EAN13CheckDigitStrategy;
import com.barcode.barcode_scanner_service.designPattern.strategyPattern.checkDigitStrategy.ITF14CheckDigitStrategy;

public class BarcodeStrategyBuilder {

    private final IBarcodeStrategy barcodeStrategy;
    
    private BarcodeStrategyBuilder(Builder builder) {
        this.barcodeStrategy = builder.barcodeStrategy;
    }

    public static Builder builder(BarcodeType barcodeType) {
        return new Builder(barcodeType);
    }

    public static class Builder {

        private final BarcodeType barcodeType;
        private IBarcodeStrategy barcodeStrategy;

        public Builder(BarcodeType barcodeType) {
            this.barcodeType = barcodeType;
        }

        public BarcodeStrategyBuilder build() {
            switch(barcodeType) {
                case EAN13:
                    this.barcodeStrategy = new EAN13Strategy(new EAN13CheckDigitStrategy());
                    break;
                case ITF14:
                    this.barcodeStrategy = new ITF14Strategy(new ITF14CheckDigitStrategy());
                    break;
                default:
                    throw new IllegalArgumentException("존재하지 않는 barcodeType 입니다.");
            }

            return new BarcodeStrategyBuilder(this);
        }

    }

    public String generateBarcode() {
        return this.barcodeStrategy.generateBarcode();
    }

}
