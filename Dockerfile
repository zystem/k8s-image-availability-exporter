FROM nimlang/nim:2.2.4-alpine AS builder

WORKDIR /src
ARG VERSION=0.1.0

RUN apk add --no-cache \
    gcc \
    musl-dev \
    openssl-dev \
    pcre-dev \
    git

COPY k8s_image_availability_exporter.nimble .
RUN nimble install --depsOnly -y

COPY src ./src

RUN nim c \
    -d:release \
    -d:ssl \
    -d:Version=$VERSION \
    --threads:on \
    --mm:orc \
    --out:/out/k8s-image-availability-exporter \
    src/k8s_image_availability_exporter.nim

FROM alpine:3.20

RUN apk add --no-cache ca-certificates curl pcre

RUN mkdir -p /data && chown 65534:65534 /data

COPY --from=builder /out/k8s-image-availability-exporter /usr/local/bin/k8s-image-availability-exporter

USER 65534:65534

EXPOSE 9090

HEALTHCHECK --interval=30s --timeout=3s \
    CMD curl -fsS http://127.0.0.1:9090/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/k8s-image-availability-exporter"]
