# ---- build stage ----------------------------------------------------------
# Pinned to the same Go version we use locally (see backend/README.md).
FROM golang:1.20.14-alpine AS build

WORKDIR /src

# Copy manifests first so `go mod download` is cached independently of source
# changes -- editing main.go should not re-download redigo.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# CGO_ENABLED=0 gives a fully static binary, so the runtime stage needs no libc.
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/backend .

# ---- runtime stage --------------------------------------------------------
FROM alpine:3.20

# Run as an unprivileged user; nothing here needs root.
RUN adduser -D -u 10001 app

COPY --from=build /out/backend /usr/local/bin/backend

USER app
EXPOSE 9000

ENTRYPOINT ["/usr/local/bin/backend"]
