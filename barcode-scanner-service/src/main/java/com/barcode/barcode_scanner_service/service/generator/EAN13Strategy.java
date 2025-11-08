package com.barcode.barcode_scanner_service.service.generator;

import java.util.Random;

/**
 * EAN-13 바코드의 생성 전략을 구현합니다.
 * * EAN-13은 소매 상품 식별(GTIN-13)에 사용되며 총 13자리 코드를 갖습니다.
 * 이 전략은 한국 GS1 표준에 따라 앞자리 데이터를 생성합니다:
 * 1. 국가 코드: '880'으로 시작합니다.
 * 2. 나머지 9자리는 랜덤으로 생성하여 총 12자리의 앞자리 데이터를 만듭니다.
 * * 최종적으로 생성자로 주입받은 ICheckDigitStrategy에게 계산을 위임하여 13자리 바코드를 완성합니다.
 */
class EAN13Strategy implements IBarcodeStrategy {

    private final ICheckDigitStrategy checkDigitStrategy;
    private static final Random RANDOM = new Random();

    EAN13Strategy(ICheckDigitStrategy checkDigitStrategy) {
        this.checkDigitStrategy = checkDigitStrategy;
    }

    @Override
    public String generateBarcode() {
        StringBuilder barcodeBuilder = new StringBuilder("880");

        for (int i = 0; i < 9; i++) {
            barcodeBuilder.append(RANDOM.nextInt(10)); 
        }

        String barcode12Digit = barcodeBuilder.toString();
        String EAN13CheckDigit = checkDigitStrategy.makeCheckDigit(barcode12Digit);

        return barcode12Digit + EAN13CheckDigit;
    }

}
