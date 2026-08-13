# syntax=docker/dockerfile:1.2@sha256:e2a8561e419ab1ba6b2fe6cbdf49fd92b95912df1cf7d313c3e2230a333fdbcc

FROM alpine@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS source
ARG COMMIT_REF=v0.2.2
RUN apk add --no-cache curl tar git
WORKDIR /src

RUN curl -sSL https://github.com/kubernetes-sigs/container-object-storage-interface/archive/${COMMIT_REF}.tar.gz \
        | tar -xz --strip-components=1

COPY patches /patches
RUN git apply /patches/*.diff

FROM --platform=$BUILDPLATFORM docker.io/golang:1.26@sha256:705e964a93a2fd2e75c7d59bb7d781b57e30f12293ffde5175c69229e18fb678 AS builder
ARG TARGETOS
ARG TARGETARCH

WORKDIR /go/src/cosi

COPY --from=source /src/go.mod /src/go.sum /src ./
RUN go mod download

RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o /build/controller ./controller/cmd \
 && CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o /build/sidecar ./sidecar/cmd

FROM gcr.io/distroless/static:nonroot@sha256:f7f8f729987ad0fdf6b05eeeae94b26e6a0f613bdf46feea7fc40f7bd72953e6 AS controller
COPY --from=builder /build/controller /controller
USER 65532:65532
ENTRYPOINT ["/controller"]

FROM gcr.io/distroless/static:nonroot@sha256:f7f8f729987ad0fdf6b05eeeae94b26e6a0f613bdf46feea7fc40f7bd72953e6 AS sidecar
COPY --from=builder /build/sidecar /sidecar
USER 65532:65532
ENTRYPOINT ["/sidecar"]
