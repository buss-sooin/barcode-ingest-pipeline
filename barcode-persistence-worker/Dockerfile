FROM eclipse-temurin:21-jdk AS build
WORKDIR /app
COPY gradlew ./
COPY gradle gradle
COPY build.gradle settings.gradle ./
COPY src src
RUN ./gradlew bootJar --no-daemon -x test

FROM eclipse-temurin:21-jre
ARG BIP_IMAGE_REVISION
WORKDIR /app
COPY --from=build /app/build/libs/*.jar app.jar
LABEL org.opencontainers.image.revision=$BIP_IMAGE_REVISION
# SERVER_PORT·WORKER_NAME은 실행 시 환경변수로 주입한다 (항목 15).
EXPOSE 8085
ENTRYPOINT ["java", "-jar", "app.jar"]
