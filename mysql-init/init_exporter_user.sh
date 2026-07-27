#!/bin/bash
# init_exporter_user.sh
# mysqld-exporter 사용자와 필요한 권한을 자동으로 설정한다.
# 사용자 이름·비밀번호는 monitoring-compose.yml과 같은 .env 값(MYSQL_EXPORTER_USER,
# MYSQL_EXPORTER_PASSWORD)을 참조해야 일치한다. .sql이 아닌 .sh인 이유: MySQL 공식
# 이미지는 docker-entrypoint-initdb.d의 .sh만 컨테이너 환경변수를 참조할 수 있게
# source하고, .sql은 고정된 내용 그대로 실행돼 환경변수를 넣을 수 없다.
set -euo pipefail

mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<-EOSQL
  CREATE USER '${MYSQL_EXPORTER_USER}'@'%' IDENTIFIED BY '${MYSQL_EXPORTER_PASSWORD}';
  GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '${MYSQL_EXPORTER_USER}'@'%';
  FLUSH PRIVILEGES;
EOSQL
