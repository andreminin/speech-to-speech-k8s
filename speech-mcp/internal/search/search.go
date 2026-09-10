// Package search defines the internet-search tool's provider interface.
// SearXNG (searxng.go) is the first implementation, but callers only
// depend on this interface - a different provider can be swapped in
// without touching the MCP tool wiring (proposal principle 7: "make
// providers replaceable").
package search

import "context"

type Result struct {
	Title   string `json:"title"`
	URL     string `json:"url"`
	Snippet string `json:"snippet"`
	Source  string `json:"source"`
}

type Input struct {
	Query      string `json:"query" jsonschema:"the search query"`
	MaxResults int    `json:"max_results,omitempty" jsonschema:"maximum number of results to return"`
}

type Output struct {
	Results []Result `json:"results"`
}

// Provider searches the public internet and returns concise, structured
// results. Implementations must bound both result count and snippet
// length themselves (proposal §23) and must treat the underlying
// provider's response as untrusted data (proposal §13).
type Provider interface {
	Search(ctx context.Context, query string, maxResults int) ([]Result, error)
}
