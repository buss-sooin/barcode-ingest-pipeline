-- KEYS[1] = 중복 표시 키 (barcode:processed:{originalBarcode})
-- KEYS[2] = 대상 스트림 키
-- ARGV[1] = internalBarcodeId
-- ARGV[2] = originalBarcode
-- ARGV[3] = deviceId
-- ARGV[4] = scanTime
-- ARGV[5] = processedTime
-- ARGV[6] = 중복 표시 TTL(초)
--
-- 중복 체크, 스트림 발행, 표시를 한 스크립트 안에서 원자적으로 처리한다.
-- 클라이언트 쪽에서 두 번의 Redis 왕복으로 나누면 그 사이 창에서
-- 재시도가 자기 표시에 막히거나(먼저 표시하는 경우) 동시 요청이 중복 발행되는(먼저
-- 발행하는 경우) 문제가 생긴다 — 둘 다 이 스크립트 하나로 없앤다.
if redis.call('EXISTS', KEYS[1]) == 1 then
    return 0
end

redis.call('XADD', KEYS[2], '*',
    'internalBarcodeId', ARGV[1],
    'originalBarcode', ARGV[2],
    'deviceId', ARGV[3],
    'scanTime', ARGV[4],
    'processedTime', ARGV[5])

redis.call('SET', KEYS[1], ARGV[1], 'EX', ARGV[6])

return 1
