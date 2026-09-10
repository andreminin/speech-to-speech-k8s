// Package config loads speech-mcp's runtime configuration from
// environment variables. See k8s/speech-mcp/deployment.yaml for the
// actual values used in the cluster.
package config

import (
	"net/url"
	"os"
	"time"
)

type Config struct {
	// HTTPAddr is where the MCP Streamable HTTP handler (and the plain
	// /health/* endpoints) listen.
	HTTPAddr string

	// SearchAPIURL is the SearXNG instance's search endpoint, e.g.
	// "http://searxng:8080/search". JSON output must be enabled there
	// (see k8s/searxng/configmap.yaml) or every request gets a 403.
	SearchAPIURL string

	// SearchHealthURL is SearXNG's own /healthz route, derived from
	// SearchAPIURL's scheme+host. Used for speech-mcp's readiness check
	// instead of firing a real search query - SearXNG's own maintainers
	// note that hitting /search for health checks is fragile and adds
	// unnecessary load (see speech-mcp/README.md).
	SearchHealthURL string

	// ToolMaxResults caps global_internet_search's result count -
	// callers can ask for fewer, never more (proposal §23).
	ToolMaxResults int

	// ToolTimeout bounds every external call (SearXNG, and any future
	// tool) - a voice assistant must fail fast rather than hang
	// (proposal §22).
	ToolTimeout time.Duration

	// DefaultTimezone is used by local_time when the caller doesn't
	// specify one.
	DefaultTimezone string
}

func Load() Config {
	searchAPIURL := getEnv("SEARCH_API_URL", "http://searxng:8080/search")
	return Config{
		HTTPAddr:        getEnv("MCP_HTTP_ADDR", ":8080"),
		SearchAPIURL:    searchAPIURL,
		SearchHealthURL: healthURL(searchAPIURL),
		ToolMaxResults:  getEnvInt("TOOL_MAX_RESULTS", 5),
		ToolTimeout:     getEnvDuration("TOOL_TIMEOUT", 5*time.Second),
		DefaultTimezone: getEnv("MCP_DEFAULT_TIMEZONE", "UTC"),
	}
}

// healthURL derives "<scheme>://<host>/healthz" from a search endpoint
// URL like "http://searxng:8080/search". Falls back to the input
// unchanged if it doesn't parse (readiness check will then just fail
// closed rather than crash).
func healthURL(searchAPIURL string) string {
	u, err := url.Parse(searchAPIURL)
	if err != nil {
		return searchAPIURL
	}
	u.Path = "/healthz"
	u.RawQuery = ""
	return u.String()
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getEnvInt(key string, def int) int {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n := 0
	for _, c := range v {
		if c < '0' || c > '9' {
			return def
		}
		n = n*10 + int(c-'0')
	}
	return n
}

func getEnvDuration(key string, def time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return def
	}
	return d
}
