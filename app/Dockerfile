# --- build stage -------------------------------------------------------------
FROM golang:1.23-alpine AS build
WORKDIR /src

# No external dependencies: copying go.mod is enough for caching.
COPY go.mod ./
COPY . .

ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.version=${VERSION}" \
    -o /out/app .

# --- runtime stage -----------------------------------------------------------
# distroless/static: no shell, no package manager, runs as non-root.
FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /
COPY --from=build /out/app /app
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/app"]
