package com.barcode.barcode_ingest_service.dto;

import java.util.List;

/**
 * 배치 전송 결과. failedIndices는 요청 리스트에서의 위치(0-based)를 가리킨다 — 바코드 값이
 * 아니라 인덱스로 지목하는 이유는 같은 배치 안에 같은 바코드 값이 중복으로 들어올 수 있어
 * 값만으로는 실패 건을 정확히 특정할 수 없기 때문이다.
 */
public record BatchIngestResult(int total, int succeeded, List<Integer> failedIndices) {
}
