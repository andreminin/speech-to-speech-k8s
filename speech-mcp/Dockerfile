# Experimental MCP server for speech-to-speech-k8s (see
# mcp/speech-mcp-mcp-experiment-proposal.md). CPU-only, no GPU/CUDA
# needed, so unlike gateway/stt/tts this does NOT build from the
# local-registry cuda base - a plain golang/alpine multi-stage build is
# both simpler and much smaller. Both base images are pulled directly
# from Docker Hub at build time (this machine has direct internet
# access); the pushed image is self-contained, so cluster nodes never
# need to reach Docker Hub themselves.
#
# Build: docker build -t local-registry:5000/speech-mcp:<tag> speech-mcp/
FROM golang:1.25-alpine AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/speech-mcp ./cmd/speech-mcp

FROM alpine:3.24
RUN apk add --no-cache ca-certificates
COPY --from=build /out/speech-mcp /usr/local/bin/speech-mcp

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/speech-mcp"]
