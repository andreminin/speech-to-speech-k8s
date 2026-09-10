package search

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

const (
	maxSnippetLen  = 500
	hardResultCap  = 10
	defaultResults = 5
)

// SearXNG calls a self-hosted SearXNG instance's JSON API
// (k8s/searxng/ - JSON output must be enabled there, it's off by
// default). See https://docs.searxng.org/dev/search_api.html.
type SearXNG struct {
	BaseURL string // e.g. "http://searxng:8080/search"
	Client  *http.Client
}

func NewSearXNG(baseURL string, client *http.Client) *SearXNG {
	if client == nil {
		client = http.DefaultClient
	}
	return &SearXNG{BaseURL: baseURL, Client: client}
}

type searxngResponse struct {
	Results []searxngResult `json:"results"`
}

type searxngResult struct {
	Title     string   `json:"title"`
	URL       string   `json:"url"`
	Content   string   `json:"content"`
	Engine    string   `json:"engine"`
	ParsedURL []string `json:"parsed_url"`
}

func (s *SearXNG) Search(ctx context.Context, query string, maxResults int) ([]Result, error) {
	if maxResults <= 0 {
		maxResults = defaultResults
	}
	if maxResults > hardResultCap {
		maxResults = hardResultCap
	}

	u, err := url.Parse(s.BaseURL)
	if err != nil {
		return nil, fmt.Errorf("invalid SearXNG base URL: %w", err)
	}
	q := u.Query()
	q.Set("q", query)
	q.Set("format", "json")
	u.RawQuery = q.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("building search request: %w", err)
	}

	resp, err := s.Client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("search request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return nil, fmt.Errorf("search backend returned HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var parsed searxngResponse
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return nil, fmt.Errorf("decoding search response: %w", err)
	}

	results := make([]Result, 0, maxResults)
	for _, r := range parsed.Results {
		if len(results) >= maxResults {
			break
		}
		results = append(results, Result{
			Title:   r.Title,
			URL:     r.URL,
			Snippet: truncate(r.Content, maxSnippetLen),
			Source:  resultSource(r),
		})
	}
	return results, nil
}

func resultSource(r searxngResult) string {
	if len(r.ParsedURL) > 1 && r.ParsedURL[1] != "" {
		return r.ParsedURL[1]
	}
	if u, err := url.Parse(r.URL); err == nil && u.Host != "" {
		return u.Host
	}
	return r.Engine
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
