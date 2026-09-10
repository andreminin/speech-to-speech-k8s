// Package localtime implements the local_time MCP tool: pure
// computation, no external dependencies - a deliberately simple second
// tool for the PoC (see mcp/speech-mcp-mcp-experiment-proposal.md).
package localtime

import (
	"fmt"
	"time"
)

type Input struct {
	// Timezone is an IANA timezone name (e.g. "America/New_York").
	// Empty means "use the server's configured default".
	Timezone string `json:"timezone,omitempty" jsonschema:"IANA timezone name, e.g. 'America/New_York' or 'Asia/Tokyo'; defaults to the server's configured timezone if omitted"`
}

type Output struct {
	Timezone string `json:"timezone"`
	ISO8601  string `json:"iso8601"`
	Unix     int64  `json:"unix"`
	Weekday  string `json:"weekday"`
}

// Provider resolves the current time for a given (or default) timezone.
type Provider struct {
	DefaultTimezone string
}

func (p Provider) Now(input Input) (Output, error) {
	tz := input.Timezone
	if tz == "" {
		tz = p.DefaultTimezone
	}
	if tz == "" {
		tz = "UTC"
	}

	loc, err := time.LoadLocation(tz)
	if err != nil {
		return Output{}, fmt.Errorf("unknown timezone %q: %w", tz, err)
	}

	now := time.Now().In(loc)
	return Output{
		Timezone: tz,
		ISO8601:  now.Format(time.RFC3339),
		Unix:     now.Unix(),
		Weekday:  now.Weekday().String(),
	}, nil
}
