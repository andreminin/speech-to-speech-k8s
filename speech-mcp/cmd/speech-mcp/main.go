// speech-mcp is an experimental MCP server for speech-to-speech-k8s
// (see mcp/speech-mcp-mcp-experiment-proposal.md). This PoC exposes two
// tools - local_time and global_internet_search - over MCP Streamable
// HTTP, plus plain /health/live and /health/ready endpoints for
// Kubernetes probes.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	// Pure-Go IANA timezone database, embedded in the binary - the
	// alpine runtime image doesn't ship /usr/share/zoneinfo, and this
	// avoids depending on the OS having tzdata installed at all.
	_ "time/tzdata"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"speech-mcp/internal/config"
	"speech-mcp/internal/health"
	"speech-mcp/internal/localtime"
	"speech-mcp/internal/mcpserver"
	"speech-mcp/internal/search"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg := config.Load()

	searchProvider := search.NewSearXNG(cfg.SearchAPIURL, &http.Client{Timeout: cfg.ToolTimeout})
	timeProvider := localtime.Provider{DefaultTimezone: cfg.DefaultTimezone}

	server := mcpserver.New(timeProvider, searchProvider, cfg.ToolMaxResults)
	mcpHandler := mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server {
		return server
	}, &mcp.StreamableHTTPOptions{
		Stateless: true,
		Logger:    logger,
		// Plain JSON responses instead of SSE framing - callers (the demo's
		// /api/mcp/call proxy) do a single request/response tools/call and
		// don't need a streaming connection.
		JSONResponse: true,
	})

	mux := http.NewServeMux()
	mux.Handle("/mcp", mcpHandler)
	health.Register(mux, func(ctx context.Context) error {
		ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, cfg.SearchHealthURL, nil)
		if err != nil {
			return err
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		return nil
	})

	httpServer := &http.Server{
		Addr:    cfg.HTTPAddr,
		Handler: mux,
	}

	logger.Info("speech-mcp starting",
		"addr", cfg.HTTPAddr,
		"search_api_url", cfg.SearchAPIURL,
		"tool_max_results", cfg.ToolMaxResults,
		"tool_timeout", cfg.ToolTimeout.String(),
		"default_timezone", cfg.DefaultTimezone,
	)

	go func() {
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("http server failed", "error", err)
			os.Exit(1)
		}
	}()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	<-ctx.Done()

	logger.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = httpServer.Shutdown(shutdownCtx)
}
