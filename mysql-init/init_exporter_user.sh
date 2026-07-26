#!/bin/bash
# .sql은 환경변수를 못 읽어서 .sh로 만들었다. MYSQL_EXPORTER_USER/PASSWORD는
# monitoring-compose.yml의 .env 값과 같아야 한다.
set -euo pipefail

mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<-EOSQL
  CREATE USER '${MYSQL_EXPORTER_USER}'@'%' IDENTIFIED BY '${MYSQL_EXPORTER_PASSWORD}';
  GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '${MYSQL_EXPORTER_USER}'@'%';
  FLUSH PRIVILEGES;
EOSQL
