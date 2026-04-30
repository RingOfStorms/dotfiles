// bifrost-models — regenerate hosts/h001/mods/bifrost_models.nix from the
// upstream provider /models endpoints and the models.dev pricing catalog.
//
// What it does:
//  1. Fetch air_prd /models (LiteLLM-style {data:[{id}...]}). These are the
//     models reachable through Bifrost's `air` custom_provider_config.
//  2. Fetch openrouter /models. Pricing is embedded in the response (per-token
//     strings); use it directly — it's the most accurate source for OR.
//  3. Fetch models.dev /api.json for the air-side pricing match. Costs there
//     are per-million tokens — divide by 1e6 to match Bifrost's per-token
//     schema.
//  4. Fuzzy-match each air model id against models.dev (token + Levenshtein,
//     ported from MVA's matcher). Skip models below confidence 0.5 and warn
//     to stderr — Bifrost will leave cost as `—` for those.
//  5. Emit hosts/h001/mods/bifrost_models.nix with two attrs:
//     airPricingOverrides + openrouterPricingOverrides.
//
// Endpoints come from env (with sensible defaults for h001 on the work
// tailnet); see flag definitions in main(). Run inside the dev shell.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// ─── HTTP ──────────────────────────────────────────────────────────────────

var httpClient = &http.Client{Timeout: 30 * time.Second}

func httpGetJSON(url, bearer string, out any) error {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return err
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("GET %s: %s\n%s", url, resp.Status, string(body))
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// ─── Provider responses ────────────────────────────────────────────────────

// LiteLLM/OpenAI-style /models response.
type openAIModelsResp struct {
	Data []struct {
		ID string `json:"id"`
	} `json:"data"`
}

// OpenRouter's /models response embeds per-token pricing as decimal strings.
// Fields we care about: prompt (input), completion (output), and the
// optional cache fields. Anything missing or "0" is treated as unknown.
type openRouterModelsResp struct {
	Data []openRouterModel `json:"data"`
}

type openRouterModel struct {
	ID      string             `json:"id"`
	Pricing openRouterPricing  `json:"pricing"`
}

type openRouterPricing struct {
	Prompt           string `json:"prompt"`
	Completion       string `json:"completion"`
	InputCacheRead   string `json:"input_cache_read"`
	InputCacheWrite  string `json:"input_cache_write"`
}

// ─── models.dev ────────────────────────────────────────────────────────────

// models.dev shape: provider_id → { models: { model_id → entry } }.
// Costs are USD per *million* tokens. We convert to per-token at emit time.
type modelsDevResp map[string]struct {
	Models map[string]modelsDevModel `json:"models"`
}

type modelsDevModel struct {
	Cost *struct {
		Input      *float64 `json:"input"`
		Output     *float64 `json:"output"`
		CacheRead  *float64 `json:"cache_read"`
		CacheWrite *float64 `json:"cache_write"`
	} `json:"cost"`
}

// Flattened pricing entry: per-million-token costs (matching models.dev's
// native units). nil means unknown/missing.
type pricingEntry struct {
	InputPerM      *float64
	OutputPerM     *float64
	CacheReadPerM  *float64
	CacheWritePerM *float64
}

func (p pricingEntry) hasCost() bool {
	return (p.InputPerM != nil && *p.InputPerM > 0) ||
		(p.OutputPerM != nil && *p.OutputPerM > 0)
}

// CANONICAL_PROVIDERS — order matters (first = highest priority). Mirrors
// MVA's list; entries from these providers win ties so e.g. claude-opus-4
// resolves to Anthropic's pricing rather than a routing-only entry.
var canonicalProviders = []string{
	"anthropic", "openai", "google", "meta", "mistral",
	"cohere", "deepseek", "amazon",
}

func authorityScore(e pricingEntry, providerID string) int {
	score := 0
	if e.hasCost() {
		score += 100
	}
	for i, p := range canonicalProviders {
		if p == providerID {
			score += (len(canonicalProviders) - i) * 5
			break
		}
	}
	return score
}

// ─── Fuzzy matching ────────────────────────────────────────────────────────
//
// Ported from mva-core/src/models.rs (find_best_match). Two scores combined:
// token overlap (50%) + Levenshtein similarity (30%) + substring bonus (20%).
// Threshold 0.5; below that we treat the model as unmatched.
//
// Why both: token-only misses things like "gpt-5-mini" vs "gpt-5-mini-2025-…"
// once dates are stripped, and Levenshtein alone gets fooled by prefix soup
// like "air-claude-…" vs "claude-…".

func normalizeModelName(s string) string {
	s = strings.ToLower(s)
	for _, prefix := range []string{"air-", "azure-", "copilot-", "openai-", "local-"} {
		s = strings.TrimPrefix(s, prefix)
	}
	s = strings.ReplaceAll(s, ".", "-")
	s = strings.ReplaceAll(s, "--", "-")
	return s
}

func splitTokens(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool {
		return r == '-' || r == '_' || r == '.'
	})
}

// tokenMatchScore — fraction of meaningful tokens in `provider` that also
// appear in `candidate`. Drops prefixes, dates, and pure numbers.
func tokenMatchScore(provider, candidate string) float64 {
	skip := func(t string) bool {
		switch t {
		case "air", "azure", "copilot", "openai", "local", "openrouter":
			return true
		}
		if len(t) <= 1 {
			return true
		}
		for _, r := range t {
			if r < '0' || r > '9' {
				return false
			}
		}
		return true // all-digit
	}
	pTokens := splitTokens(provider)
	cTokens := splitTokens(candidate)
	cSet := map[string]bool{}
	for _, t := range cTokens {
		cSet[t] = true
	}
	meaningful := 0
	matched := 0
	for _, t := range pTokens {
		if skip(t) {
			continue
		}
		meaningful++
		if cSet[t] {
			matched++
		}
	}
	if meaningful == 0 {
		return 0
	}
	return float64(matched) / float64(meaningful)
}

func levenshteinSim(a, b string) float64 {
	ar := []rune(a)
	br := []rune(b)
	la, lb := len(ar), len(br)
	if la == 0 && lb == 0 {
		return 1
	}
	maxLen := la
	if lb > maxLen {
		maxLen = lb
	}
	prev := make([]int, lb+1)
	curr := make([]int, lb+1)
	for j := 0; j <= lb; j++ {
		prev[j] = j
	}
	for i := 1; i <= la; i++ {
		curr[0] = i
		for j := 1; j <= lb; j++ {
			cost := 1
			if ar[i-1] == br[j-1] {
				cost = 0
			}
			curr[j] = min3(prev[j]+1, curr[j-1]+1, prev[j-1]+cost)
		}
		prev, curr = curr, prev
	}
	return float64(maxLen-prev[lb]) / float64(maxLen)
}

func min3(a, b, c int) int {
	if a < b {
		b = a
	}
	if c < b {
		return c
	}
	return b
}

// findBestMatch — returns canonical id, entry, score; ok=false below 0.5.
func findBestMatch(providerID string, catalog map[string]pricingEntry) (string, pricingEntry, float64, bool) {
	pNorm := normalizeModelName(providerID)
	bestID := ""
	bestScore := 0.0
	var bestEntry pricingEntry
	have := false
	for cid, entry := range catalog {
		cNorm := normalizeModelName(cid)
		tok := tokenMatchScore(pNorm, cNorm)
		lev := levenshteinSim(pNorm, cNorm)
		sub := 0.0
		if strings.Contains(cNorm, pNorm) || strings.Contains(pNorm, cNorm) {
			sub = 0.2
		}
		combined := tok*0.5 + lev*0.3 + sub*0.2
		take := false
		if !have {
			take = true
		} else {
			gap := combined - bestScore
			thisCost := entry.hasCost()
			bestCost := bestEntry.hasCost()
			switch {
			case gap > 0.05:
				take = true
			case gap >= -0.05 && thisCost && !bestCost:
				take = true
			case gap > 0 && !(bestCost && !thisCost):
				take = true
			}
		}
		if take {
			bestID = cid
			bestEntry = entry
			bestScore = combined
			have = true
		}
	}
	if bestScore < 0.5 {
		return "", pricingEntry{}, bestScore, false
	}
	return bestID, bestEntry, bestScore, true
}

// flattenModelsDev collapses {provider → {models → entry}} into a single
// {model_id → entry} map, preferring authoritative entries on collision.
func flattenModelsDev(raw modelsDevResp) map[string]pricingEntry {
	out := map[string]pricingEntry{}
	scores := map[string]int{}
	for providerID, prov := range raw {
		for modelID, m := range prov.Models {
			e := pricingEntry{}
			if m.Cost != nil {
				e.InputPerM = m.Cost.Input
				e.OutputPerM = m.Cost.Output
				e.CacheReadPerM = m.Cost.CacheRead
				e.CacheWritePerM = m.Cost.CacheWrite
			}
			s := authorityScore(e, providerID)
			if s > scores[modelID] {
				out[modelID] = e
				scores[modelID] = s
			}
		}
	}
	return out
}

// ─── Override emission ─────────────────────────────────────────────────────
//
// One Nix attrset per model. `pricing_patch` MUST be a JSON-encoded *string*
// — that's how Bifrost's pricing-override config parses it (see
// framework/configstore/tables/pricingoverride.go: `PricingPatchJSON string`).
// We only emit fields with real values; nil fields are omitted.

type override struct {
	ID           string  // stable; used by Bifrost for upsert reconciliation
	Name         string  // human-readable
	ProviderID   string  // matches the providers map key (e.g. "air")
	Pattern      string  // model name as the upstream knows it
	InputPerTok  *float64
	OutputPerTok *float64
	CacheRdPerTok *float64
	CacheWrPerTok *float64
	Note         string // optional comment for the source line (e.g. matched canonical name)
}

// nixFloat — Nix accepts scientific notation; render with enough precision
// to round-trip a per-token cost down to 1e-9. %g drops trailing zeros.
func nixFloat(v float64) string {
	return strconv.FormatFloat(v, 'g', 12, 64)
}

// emitPricingPatch builds the JSON-string value for `pricing_patch`. We use
// encoding/json so escaping is correct; only non-nil fields are included.
func emitPricingPatch(o override) string {
	m := map[string]float64{}
	if o.InputPerTok != nil {
		m["input_cost_per_token"] = *o.InputPerTok
	}
	if o.OutputPerTok != nil {
		m["output_cost_per_token"] = *o.OutputPerTok
	}
	if o.CacheRdPerTok != nil {
		m["cache_read_input_token_cost"] = *o.CacheRdPerTok
	}
	if o.CacheWrPerTok != nil {
		m["cache_creation_input_token_cost"] = *o.CacheWrPerTok
	}
	b, _ := json.Marshal(m)
	return string(b)
}

// parseORPrice — OpenRouter prices are decimal strings, already per-token.
// Empty / "0" → nil (treat as unknown so the override doesn't pin a $0 rate
// that would silently mask a real cost regression upstream).
func parseORPrice(s string) *float64 {
	if s == "" {
		return nil
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil || v <= 0 {
		return nil
	}
	return &v
}

func emitOverride(b *strings.Builder, o override) {
	if o.Note != "" {
		fmt.Fprintf(b, "    # %s\n", o.Note)
	}
	fmt.Fprintf(b, "    {\n")
	fmt.Fprintf(b, "      id = %q;\n", o.ID)
	fmt.Fprintf(b, "      name = %q;\n", o.Name)
	fmt.Fprintf(b, "      scope_kind = \"provider\";\n")
	fmt.Fprintf(b, "      provider_id = %q;\n", o.ProviderID)
	fmt.Fprintf(b, "      match_type = \"exact\";\n")
	fmt.Fprintf(b, "      pattern = %q;\n", o.Pattern)
	fmt.Fprintf(b, "      request_types = [ \"chat_completion\" ];\n")
	// Embed the JSON patch as a Nix string. encoding/json already
	// escapes \" and \\; Nix needs the same escapes inside "...".
	patch := emitPricingPatch(o)
	patch = strings.ReplaceAll(patch, `\`, `\\`)
	patch = strings.ReplaceAll(patch, `"`, `\"`)
	fmt.Fprintf(b, "      pricing_patch = \"%s\";\n", patch)
	fmt.Fprintf(b, "    }\n")
}

// ─── Output path ───────────────────────────────────────────────────────────

// repoRoot — `git rev-parse --show-toplevel`, so the script works from any
// subdir of the nixos-config checkout.
func repoRoot() (string, error) {
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", fmt.Errorf("git rev-parse --show-toplevel failed (run inside the nixos-config repo): %w", err)
	}
	return strings.TrimSpace(string(out)), nil
}

// ─── Main ──────────────────────────────────────────────────────────────────

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	airBase := flag.String("air-base", envOr("AIR_BASE_URL", "http://100.64.0.8:9010/air_prd"),
		"upstream LiteLLM base for the `air` provider (env: AIR_BASE_URL)")
	orBase := flag.String("openrouter-base", envOr("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1"),
		"OpenRouter API base (env: OPENROUTER_BASE_URL)")
	orKey := flag.String("openrouter-key", os.Getenv("OPENROUTER_API_KEY"),
		"OpenRouter API key (env: OPENROUTER_API_KEY); /models works without auth but rate-limited")
	outFlag := flag.String("o", "", "output path (default: <repo>/hosts/h001/mods/bifrost_models.nix)")
	skipOR := flag.Bool("skip-openrouter", false, "skip OpenRouter sync (useful when offline)")
	flag.Parse()

	// Resolve output path.
	outPath := *outFlag
	if outPath == "" {
		root, err := repoRoot()
		if err != nil {
			die(err)
		}
		outPath = filepath.Join(root, "hosts/h001/mods/bifrost_models.nix")
	}

	// Fetch upstream model lists.
	fmt.Fprintf(os.Stderr, "→ fetching air models from %s/models\n", *airBase)
	var airResp openAIModelsResp
	if err := httpGetJSON(*airBase+"/models", "", &airResp); err != nil {
		die(fmt.Errorf("fetch air models: %w", err))
	}
	airIDs := make([]string, 0, len(airResp.Data))
	for _, m := range airResp.Data {
		if m.ID != "" {
			airIDs = append(airIDs, m.ID)
		}
	}
	sort.Strings(airIDs)
	fmt.Fprintf(os.Stderr, "  got %d air models\n", len(airIDs))

	var orModels []openRouterModel
	if !*skipOR {
		fmt.Fprintf(os.Stderr, "→ fetching openrouter models from %s/models\n", *orBase)
		var orResp openRouterModelsResp
		if err := httpGetJSON(*orBase+"/models", *orKey, &orResp); err != nil {
			die(fmt.Errorf("fetch openrouter models: %w", err))
		}
		orModels = orResp.Data
		sort.Slice(orModels, func(i, j int) bool { return orModels[i].ID < orModels[j].ID })
		fmt.Fprintf(os.Stderr, "  got %d openrouter models\n", len(orModels))
	}

	fmt.Fprintf(os.Stderr, "→ fetching models.dev catalog\n")
	var mdRaw modelsDevResp
	if err := httpGetJSON("https://models.dev/api.json", "", &mdRaw); err != nil {
		die(fmt.Errorf("fetch models.dev: %w", err))
	}
	catalog := flattenModelsDev(mdRaw)
	fmt.Fprintf(os.Stderr, "  flattened to %d entries\n", len(catalog))

	// Match air models against models.dev.
	var airOverrides []override
	matched, skipped := 0, 0
	for _, id := range airIDs {
		canonID, entry, score, ok := findBestMatch(id, catalog)
		if !ok {
			fmt.Fprintf(os.Stderr, "  skip air/%s — best score %.2f below 0.5 threshold\n", id, score)
			skipped++
			continue
		}
		if !entry.hasCost() {
			fmt.Fprintf(os.Stderr, "  skip air/%s — matched %s (%.2f) but entry has no cost\n", id, canonID, score)
			skipped++
			continue
		}
		o := override{
			ID:         "air-" + slugify(id),
			Name:       fmt.Sprintf("air → %s (matched %s, score %.2f)", id, canonID, score),
			ProviderID: "air",
			Pattern:    id,
			Note:       fmt.Sprintf("air/%s ← models.dev/%s (score %.2f)", id, canonID, score),
		}
		o.InputPerTok = perMillionToPerToken(entry.InputPerM)
		o.OutputPerTok = perMillionToPerToken(entry.OutputPerM)
		o.CacheRdPerTok = perMillionToPerToken(entry.CacheReadPerM)
		o.CacheWrPerTok = perMillionToPerToken(entry.CacheWritePerM)
		airOverrides = append(airOverrides, o)
		matched++
	}
	fmt.Fprintf(os.Stderr, "  air: %d matched, %d skipped\n", matched, skipped)

	// OpenRouter: pricing comes from the response itself.
	var orOverrides []override
	orMatched, orSkipped := 0, 0
	for _, m := range orModels {
		in := parseORPrice(m.Pricing.Prompt)
		out := parseORPrice(m.Pricing.Completion)
		if in == nil && out == nil {
			orSkipped++
			continue
		}
		o := override{
			ID:         "openrouter-" + slugify(m.ID),
			Name:       "openrouter → " + m.ID,
			ProviderID: "openrouter",
			Pattern:    m.ID,
			Note:       "openrouter/" + m.ID,
			InputPerTok:   in,
			OutputPerTok:  out,
			CacheRdPerTok: parseORPrice(m.Pricing.InputCacheRead),
			CacheWrPerTok: parseORPrice(m.Pricing.InputCacheWrite),
		}
		orOverrides = append(orOverrides, o)
		orMatched++
	}
	fmt.Fprintf(os.Stderr, "  openrouter: %d with pricing, %d skipped (zero/free)\n", orMatched, orSkipped)

	// Defensive: bail before writing if any id collides. Bifrost's config
	// loader rejects duplicates at startup ("a record with this id already
	// exists") which is much harder to debug than a script-time failure.
	// Check air + openrouter together since they share the same id namespace
	// in the persisted governance_pricing_overrides table.
	if dups := findDuplicateIDs(airOverrides, orOverrides); len(dups) > 0 {
		for _, d := range dups {
			fmt.Fprintf(os.Stderr, "  duplicate id %q from patterns: %v\n", d.id, d.patterns)
		}
		die(fmt.Errorf("%d duplicate override id(s); fix slugify() or rename upstream model aliases", len(dups)))
	}

	// Render Nix file.
	out := renderNix(airOverrides, orOverrides, *airBase, *orBase, *skipOR)
	if err := os.WriteFile(outPath, []byte(out), 0644); err != nil {
		die(fmt.Errorf("write %s: %w", outPath, err))
	}
	fmt.Fprintf(os.Stderr, "✓ wrote %s (%d air + %d openrouter overrides)\n", outPath, len(airOverrides), len(orOverrides))
}

func die(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}

// findDuplicateIDs — scans both override lists for colliding `id` values.
// Returns one entry per duplicate id with all the patterns that produced it.
func findDuplicateIDs(lists ...[]override) []struct {
	id       string
	patterns []string
} {
	seen := map[string][]string{}
	for _, l := range lists {
		for _, o := range l {
			seen[o.ID] = append(seen[o.ID], o.Pattern)
		}
	}
	var out []struct {
		id       string
		patterns []string
	}
	for id, pats := range seen {
		if len(pats) > 1 {
			out = append(out, struct {
				id       string
				patterns []string
			}{id, pats})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].id < out[j].id })
	return out
}

// perMillionToPerToken — models.dev gives USD per 1M tokens; Bifrost wants
// USD per token. nil propagates.
func perMillionToPerToken(v *float64) *float64 {
	if v == nil {
		return nil
	}
	r := *v / 1_000_000.0
	return &r
}

// renderNix — emit the full bifrost_models.nix. The file is a pure-data Nix
// expression returning an attrset; bifrost.nix imports it and concatenates
// the lists into governance.pricing_overrides. No `pkgs`, no `lib` — keeps
// the file evaluable in isolation (handy for `nix eval -f ...`).
func renderNix(air, or []override, airBase, orBase string, skipOR bool) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# DO NOT EDIT — generated by scripts/bifrost_models.\n")
	fmt.Fprintf(&b, "# Regenerate with: `nix develop` then `bifrost-models`.\n")
	fmt.Fprintf(&b, "#\n")
	fmt.Fprintf(&b, "# Sources:\n")
	fmt.Fprintf(&b, "#   air models:        %s/models\n", airBase)
	if skipOR {
		fmt.Fprintf(&b, "#   openrouter models: <skipped>\n")
	} else {
		fmt.Fprintf(&b, "#   openrouter models: %s/models (pricing inline)\n", orBase)
	}
	fmt.Fprintf(&b, "#   air pricing:       https://models.dev/api.json (fuzzy-matched)\n")
	fmt.Fprintf(&b, "#\n")
	fmt.Fprintf(&b, "# Generated %s.\n", time.Now().UTC().Format(time.RFC3339))
	fmt.Fprintf(&b, "{\n")
	fmt.Fprintf(&b, "  # Models exposed by upstream air_prd at sync time. Reference list;\n")
	fmt.Fprintf(&b, "  # not currently consumed by bifrost.nix but useful for sanity-checking\n")
	fmt.Fprintf(&b, "  # what `air/<model>` calls will actually route to.\n")
	fmt.Fprintf(&b, "  airModels = [\n")
	for _, o := range air {
		fmt.Fprintf(&b, "    %q\n", o.Pattern)
	}
	fmt.Fprintf(&b, "  ];\n\n")

	fmt.Fprintf(&b, "  airPricingOverrides = [\n")
	for _, o := range air {
		emitOverride(&b, o)
	}
	fmt.Fprintf(&b, "  ];\n\n")

	fmt.Fprintf(&b, "  openrouterPricingOverrides = [\n")
	for _, o := range or {
		emitOverride(&b, o)
	}
	fmt.Fprintf(&b, "  ];\n")
	fmt.Fprintf(&b, "}\n")
	return b.String()
}

// slugify — turn a model id into something safe for use as a Bifrost
// pricing-override `id`. Override ids are persisted in SQLite and used as
// upsert keys (Bifrost has no regex constraint on the field), so stability
// matters more than aesthetics.
//
// Map `.` → `_` (not `-`) so we don't collide on model names that already
// contain a dash variant of the same family. air_prd exposes both
// `claude-opus-4-7` (the literal upstream id) and `claude-opus-4.7` (their
// dotted alias) — collapsing both with `.` → `-` produced two
// `air-claude-opus-4-7` rows and Bifrost rejected the duplicate id
// ("a record with this id already exists") on startup. Slashes (used by
// OpenRouter, e.g. `anthropic/claude-3.5-sonnet`) also become `_` so the
// id stays in [a-z0-9_-].
func slugify(s string) string {
	s = strings.ToLower(s)
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '-':
			b.WriteRune(r)
		case r == '.', r == '/':
			b.WriteRune('_')
		default:
			b.WriteRune('-')
		}
	}
	out := b.String()
	for strings.Contains(out, "--") {
		out = strings.ReplaceAll(out, "--", "-")
	}
	return strings.Trim(out, "-_")
}
