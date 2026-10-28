# syntax=docker/dockerfile:1
# Build: static, reproducible-ish binary (no cgo, trimmed paths, no VCS stamping).
# Build stage runs natively on the builder and cross-compiles for each target
# platform (no QEMU emulation needed).
FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
ARG VERSION=dev
ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -buildvcs=false \
    -ldflags="-s -w -X main.version=${VERSION}" -o /out/server ./cmd/server

# Runtime: distroless static, non-root (uid 65532), no shell or package manager.
FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/server /server
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/server"]
