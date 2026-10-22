# Multi-stage: build the static binary, ship it in scratch.
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
# No external dependencies; stdlib only.
COPY cmd/ ./cmd/
COPY internal/ ./internal/
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /hh-agent ./cmd/hh-agent

FROM scratch
COPY --from=build /hh-agent /hh-agent
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
# The daemon expects these mounts at runtime (see SPEC.md §11):
#   /var/run/docker.sock -> /var/run/docker.sock (rw)
#   /proc                -> /host/proc          (ro)
#   /sys                 -> /host/sys           (ro)
#   named volume         -> /var/lib/hh-agent   (audit log, token hashes)
ENTRYPOINT ["/hh-agent"]
CMD ["serve"]
