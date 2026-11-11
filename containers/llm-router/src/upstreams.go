package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"regexp"
	"strings"
)

type upstreamConfig struct {
	Name       string `json:"name"`
	Type       string `json:"type"`
	BaseURL    string `json:"base_url,omitempty"`
	BaseURLEnv string `json:"base_url_env,omitempty"`
	APIKeyEnv  string `json:"api_key_env,omitempty"`
}

var (
	upstreamNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]*$`)
	envNamePattern      = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
)

// loadUpstreams reads and validates the --upstreams JSON file without including
// configured URL values in errors.
func loadUpstreams(path string) ([]upstreamConfig, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open upstream config: %w", err)
	}
	defer file.Close()

	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	var upstreams []upstreamConfig
	if err := decoder.Decode(&upstreams); err != nil {
		return nil, fmt.Errorf("decode upstream config: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return nil, errors.New("decode upstream config: expected one JSON value")
		}
		return nil, fmt.Errorf("decode upstream config: %w", err)
	}
	return validateUpstreams(upstreams)
}

// validateUpstreams resolves URL environment variables and returns normalized
// API roots. The returned values contain effective URLs and no env indirection.
func validateUpstreams(upstreams []upstreamConfig) ([]upstreamConfig, error) {
	if len(upstreams) == 0 {
		return nil, errors.New("upstream config must contain at least one upstream")
	}
	validated := make([]upstreamConfig, len(upstreams))
	seen := make(map[string]struct{}, len(upstreams))
	for i, upstream := range upstreams {
		if upstream.Name == "" || strings.TrimSpace(upstream.Name) != upstream.Name || !upstreamNamePattern.MatchString(upstream.Name) {
			return nil, fmt.Errorf("upstream %d has an invalid name", i)
		}
		if _, ok := seen[upstream.Name]; ok {
			return nil, fmt.Errorf("duplicate upstream name %q", upstream.Name)
		}
		seen[upstream.Name] = struct{}{}

		switch upstream.Type {
		case "copilot", "litellm":
		case "openrouter":
			if upstream.APIKeyEnv == "" {
				return nil, fmt.Errorf("upstream %q requires api_key_env", upstream.Name)
			}
		default:
			return nil, fmt.Errorf("upstream %q has an unsupported type", upstream.Name)
		}

		if (upstream.BaseURL == "") == (upstream.BaseURLEnv == "") {
			return nil, fmt.Errorf("upstream %q must specify exactly one of base_url or base_url_env", upstream.Name)
		}
		if upstream.BaseURLEnv != "" {
			if !envNamePattern.MatchString(upstream.BaseURLEnv) {
				return nil, fmt.Errorf("upstream %q has an invalid base_url_env name", upstream.Name)
			}
			value, ok := os.LookupEnv(upstream.BaseURLEnv)
			if !ok || strings.TrimSpace(value) == "" {
				return nil, fmt.Errorf("upstream %q base_url_env is not set", upstream.Name)
			}
			upstream.BaseURL = strings.TrimSpace(value)
		}
		if upstream.APIKeyEnv != "" && !envNamePattern.MatchString(upstream.APIKeyEnv) {
			return nil, fmt.Errorf("upstream %q has an invalid api_key_env name", upstream.Name)
		}
		parsed, err := url.Parse(upstream.BaseURL)
		if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" || parsed.User != nil || parsed.Opaque != "" || parsed.RawQuery != "" || parsed.Fragment != "" {
			return nil, fmt.Errorf("upstream %q has an invalid base URL", upstream.Name)
		}
		upstream.BaseURL = strings.TrimRight(parsed.String(), "/")
		upstream.BaseURLEnv = ""
		validated[i] = upstream
	}
	return validated, nil
}
