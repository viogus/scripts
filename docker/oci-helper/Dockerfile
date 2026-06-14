# syntax=docker/dockerfile:1.7

# === builder: compile oci-helper from source ===
FROM maven:3-eclipse-temurin-21-alpine AS builder

RUN apk add --no-cache git

WORKDIR /src
ARG OCI_HELPER_VERSION=v3.5.0

RUN git clone --depth 1 --branch "${OCI_HELPER_VERSION}" \
    https://github.com/Yohann0617/oci-helper.git .

RUN --mount=type=cache,target=/root/.m2 \
    mvn dependency:resolve -B -q

RUN --mount=type=cache,target=/root/.m2 \
    mvn package -B -q -DskipTests && \
    cp target/*.jar /app.jar

# === runtime: minimal JRE ===
FROM eclipse-temurin:21-jre-alpine

WORKDIR /app/oci-helper
RUN mkdir -p keys && chown -R 65534:65534 /app/oci-helper

COPY --from=builder /app.jar /oci-helper.jar
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8818
ENV JAVA_OPTS="-Xms256m -Xmx512m -XX:+UseG1GC -XX:MaxGCPauseMillis=200 --add-opens java.base/java.net=ALL-UNNAMED --add-opens java.base/sun.net.www.protocol.https=ALL-UNNAMED"

USER 65534
ENTRYPOINT ["/entrypoint.sh"]
