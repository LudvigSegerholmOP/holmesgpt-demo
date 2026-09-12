# syntax=docker/dockerfile:1
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# modernc.org/sqlite is pure Go: no cgo, fully static binary.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/holmes-bridge .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/holmes-bridge /holmes-bridge
ENV LISTEN_ADDR=:8000 DB_PATH=/data/holmes-bridge.db
VOLUME /data
EXPOSE 8000
USER nonroot
ENTRYPOINT ["/holmes-bridge"]
