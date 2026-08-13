# ---- build stage ----------------------------------------------------------
# Pinned to the same Go version we use locally (see frontend/README.md).
FROM golang:1.20.14-alpine AS build

WORKDIR /src

# No go.sum here: the frontend has no external dependencies.
COPY go.mod ./
COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/frontend .

# ---- runtime stage --------------------------------------------------------
FROM alpine:3.20

RUN adduser -D -u 10001 app

# main.go loads "./templates/fortunes.html" and serves http.Dir("./static"),
# both relative to the working directory -- so WORKDIR must be where they live.
WORKDIR /app

COPY --from=build /out/frontend /app/frontend
COPY --from=build /src/static /app/static
COPY --from=build /src/templates /app/templates

USER app
EXPOSE 8080

ENTRYPOINT ["/app/frontend"]
