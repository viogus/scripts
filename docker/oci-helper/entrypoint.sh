#!/bin/sh
set -eu

CONF="/app/oci-helper/application.yml"
DB="/app/oci-helper/oci-helper.db"

# generate default config if not mounted
if [ ! -f "$CONF" ]; then
  OCI_USERNAME="${OCI_USERNAME:-admin}"
  if [ -z "${OCI_PASSWORD:-}" ]; then
    OCI_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16)
    echo "[oci-helper] OCI_PASSWORD not set; generated: ${OCI_PASSWORD}" >&2
  fi

  cat > "$CONF" << EOF
server:
  port: 8818

web:
  account: ${OCI_USERNAME}
  password: ${OCI_PASSWORD}

spring:
  datasource:
    driver-class-name: org.sqlite.JDBC
    url: jdbc:sqlite:oci-helper.db
  sql:
    init:
      mode: always

mybatis-plus:
  mapper-locations: classpath*:com/yohann/ocihelper/mapper/xml/*.xml

logging:
  pattern:
    console: "%d{yyyy-MM-dd HH:mm:ss} %-5level %msg%n"
  level:
    com.oracle.bmc: error
    c.o.b.h.c.j: error

oci-cfg:
  key-dir-path: /app/oci-helper/keys
EOF
  echo "[oci-helper] config generated: $CONF" >&2
fi

# ensure db file exists (sqlite creates it if missing, but docker volume mount needs empty file)
[ -f "$DB" ] || touch "$DB"

exec java ${JAVA_OPTS:--Xms256m -Xmx512m} -jar /oci-helper.jar
