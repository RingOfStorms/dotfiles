package main

import (
	"os"
	"strings"
)

// openRouterKey reads the OpenRouter API key that systemd passes through the
// container's EnvironmentFile. The historical LiteLLM env file may spell the
// variable differently, so accept the plausible aliases.
func openRouterKey() string {
	for _, name := range []string{"OPENROUTER_API_KEY", "OPENROUTER_KEY", "OPENROUTER_APIKEY", "OR_API_KEY"} {
		if v := strings.TrimSpace(os.Getenv(name)); v != "" {
			return v
		}
	}
	return ""
}
