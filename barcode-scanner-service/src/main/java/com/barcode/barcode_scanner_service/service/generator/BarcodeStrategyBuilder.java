package com.barcode.barcode_scanner_service.service.generator;

/**
 * BarcodeType을 구체적인 IBarcodeStrategy 구현체로 해석하는 빌더다(Strategy
 * Pattern). 호출부는 EAN13Strategy·ITF14Strategy 같은 구체 클래스를 알 필요 없이
 * BarcodeType만으로 바코드를 생성할 수 있다.
 */
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
