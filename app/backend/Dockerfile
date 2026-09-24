# syntax=docker/dockerfile:1.7
# -----------------------------------------------------------------------------
# Stage 1 — build: compila con il JDK completo e crea un runtime Java MINIMO con jlink.
# -----------------------------------------------------------------------------
FROM eclipse-temurin:25-jdk-noble AS build
WORKDIR /src
COPY src ./src
RUN javac --release 25 -Xlint:all -d out $(find src/main/java -name '*.java') \
 && jar --create --file app.jar --main-class lab.hello.App -C out .
# jlink: solo i moduli che usiamo davvero (~45 MB invece di ~200 MB di JRE completo).
# jdk.crypto.ec serve per TLS moderno se in futuro chiamiamo endpoint HTTPS.
RUN jlink --add-modules java.base,java.net.http,jdk.httpserver,jdk.crypto.ec \
          --strip-debug --no-man-pages --no-header-files --compress=zip-6 \
          --output /jre

# -----------------------------------------------------------------------------
# Stage 2 — runtime: distroless (niente shell, niente package manager), utente non-root.
# -----------------------------------------------------------------------------
FROM gcr.io/distroless/base-debian12:nonroot
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    JAVA_HOME=/opt/jre \
    PATH=/opt/jre/bin:$PATH \
    # La JVM legge i limiti del cgroup: usiamo il 75% della memoria del container come heap.
    JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"
COPY --from=build /jre /opt/jre
COPY --from=build /src/app.jar /app/app.jar
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
