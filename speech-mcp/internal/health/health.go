// Package health implements plain HTTP liveness/readiness endpoints,
// separate from the MCP Streamable HTTP handler - Kubernetes probes
// should never hit the MCP endpoint itself (proposal §18).
package health

import (
	"context"
	"net/http"
	"time"
)

// ReadyChecker reports whether a dependency (e.g. the search backend)
// is currently reachable. Readiness intentionally does not fail just
// because the search backend is briefly unavailable - local_time can
// still serve requests either way - but it does surface the check for
// operator visibility via the /health/ready response body.
type ReadyChecker func(ctx context.Context) error

func Register(mux *http.ServeMux, ready ReadyChecker) {
	mux.HandleFunc("/health/live", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	mux.HandleFunc("/health/ready", func(w http.ResponseWriter, r *http.Request) {
		if ready == nil {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("ok"))
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := ready(ctx); err != nil {
			// Still 200: the process itself is healthy and can serve
			// local_time regardless of the search backend's state -
			// see the package doc comment. The error is just reported.
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("degraded: " + err.Error()))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
}
