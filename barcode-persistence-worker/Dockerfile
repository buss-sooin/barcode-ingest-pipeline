FROM eclipse-temurin:21-jdk AS build
WORKDIR /app
COPY gradlew ./
COPY gradle gradle
COPY build.gradle settings.gradle ./
COPY src src
RUN ./gradlew bootJar --no-daemon -x test

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/build/libs/*.jar app.jar
# SERVER_PORT·WORKER_NAME은 실행 시 환경변수로 주입한다 (항목 15).
EXPOSE 8085
ENTRYPOINT ["java", "-jar", "app.jar"]
