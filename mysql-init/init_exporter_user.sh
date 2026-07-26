#!/bin/bash
# mysqld-exporter 사용자의 필요한 권한을 설정한다.
# .sql은 환경변수를 읽지 못해 .sh로 변경.
set -euo pipefail

mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<-EOSQL
  CREATE USER '${MYSQL_EXPORTER_USER}'@'%' IDENTIFIED BY '${MYSQL_EXPORTER_PASSWORD}';
  GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '${MYSQL_EXPORTER_USER}'@'%';
  FLUSH PRIVILEGES;
EOSQL
