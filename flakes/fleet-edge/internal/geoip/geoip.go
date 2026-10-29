// Package geoip resolves IP addresses to ISO-3166 alpha-2 country codes from an
// offline DB-IP Lite "IP to Country" CSV dump.
//
// The file is read once at startup and never downloaded or queried over the
// network, so the dashboard keeps working with no egress. Only globally
// routable addresses are answered: private, loopback, link-local, multicast,
// CGNAT, documentation/reserved and IPv6 ULA space is omitted instead of being
// guessed. A country here is where the address block is registered, not who the
// address belongs to.
//
// A malformed file fails Load instead of yielding a partial index: a database
// missing half its rows would still answer lookups, just wrongly, so callers
// must treat a parse error as "no country database".
package geoip

import (
	"bufio"
	"compress/gzip"
	"encoding/binary"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"sort"
	"strings"
)

// Attribution strings for the DB-IP Lite Country database (CC BY 4.0).
const (
	Source = "DB-IP Lite Country (CC BY 4.0)"
	URL    = "https://db-ip.com/db/format/ip-to-country-lite/csv.html"
	Note   = "IP registration estimate, not attacker identity"
)

// DB is an immutable address range index. Lookup is safe for concurrent use.
type DB struct {
	codes []string // index 0 is "" (unknown); ranges store an index, not a string
	v4    []v4Range
	v6    []v6Range
}

// v4Range is 12 bytes per row instead of the 24+ a netip.Addr pair would need:
// DB-IP Lite Country is ~710k rows and the whole index is kept resident.
type v4Range struct {
	start, end uint32
	code       uint8
}

type v6Range struct {
	startHi, startLo uint64
	endHi, endLo     uint64
	code             uint8
}

// Load parses a DB-IP Lite CSV (plain or gzip-compressed) at path. Any
// malformed row is an error: the file is either usable as a whole or not.
func Load(path string) (*DB, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("geoip: %w", err)
	}
	defer f.Close()

	br := bufio.NewReaderSize(f, 1<<16)
	var r io.Reader = br
	if magic, err := br.Peek(2); err == nil && magic[0] == 0x1f && magic[1] == 0x8b {
		gz, err := gzip.NewReader(br)
		if err != nil {
			return nil, fmt.Errorf("geoip %s: gzip: %w", path, err)
		}
		defer gz.Close()
		r = gz
	}
	db, err := parse(r)
	if err != nil {
		return nil, fmt.Errorf("geoip %s: %w", path, err)
	}
	return db, nil
}

// parse reads the whole dump into a sorted, overlap-free range index. Rows are
// validated rather than skipped: a header is the only tolerated non-record, and
// only when it is exactly `ip_start,ip_end,country`.
func parse(r io.Reader) (*DB, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = 3
	cr.ReuseRecord = true
	cr.Comment = '#'

	db := &DB{codes: []string{""}}
	codeIdx := map[string]uint8{}
	first := true
	for {
		row, err := cr.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		if first {
			first = false
			if isHeader(row) {
				continue
			}
		}
		start, err := parseAddr(row[0])
		if err != nil {
			return nil, fmt.Errorf("%w in ip_start", err)
		}
		end, err := parseAddr(row[1])
		if err != nil {
			return nil, fmt.Errorf("%w in ip_end", err)
		}
		cc := row[2]
		if !validCode(cc) {
			return nil, fmt.Errorf("bad country code %q (want two A-Z)", cc)
		}
		if cc == "ZZ" { // DB-IP's "unknown" placeholder: no country, no row
			continue
		}
		if start.Is4() != end.Is4() {
			return nil, fmt.Errorf("mixed address family %s-%s", row[0], row[1])
		}
		code := codeIdx[cc]
		if code == 0 {
			if len(db.codes) == 256 {
				return nil, fmt.Errorf("more than 255 country codes")
			}
			code = uint8(len(db.codes))
			db.codes = append(db.codes, cc) // copies cc out of the reused row
			codeIdx[cc] = code
		}
		if start.Is4() {
			a, b := start.As4(), end.As4()
			lo, hi := binary.BigEndian.Uint32(a[:]), binary.BigEndian.Uint32(b[:])
			if lo > hi {
				return nil, fmt.Errorf("inverted IPv4 range %s-%s", row[0], row[1])
			}
			db.v4 = append(db.v4, v4Range{start: lo, end: hi, code: code})
			continue
		}
		a, b := start.As16(), end.As16()
		r := v6Range{
			startHi: binary.BigEndian.Uint64(a[:8]), startLo: binary.BigEndian.Uint64(a[8:]),
			endHi: binary.BigEndian.Uint64(b[:8]), endLo: binary.BigEndian.Uint64(b[8:]),
			code: code,
		}
		if !r.ordered() {
			return nil, fmt.Errorf("inverted IPv6 range %s-%s", row[0], row[1])
		}
		db.v6 = append(db.v6, r)
	}
	if len(db.v4) == 0 && len(db.v6) == 0 {
		return nil, fmt.Errorf("no address ranges found (expected ip_start,ip_end,country CSV)")
	}

	sort.Slice(db.v4, func(i, j int) bool { return db.v4[i].start < db.v4[j].start })
	sort.Slice(db.v6, func(i, j int) bool { return db.v6[i].less(db.v6[j]) })

	// Lookup binary-searches the last range starting at or before the address,
	// so overlapping rows would answer with whichever sorted first. Reject them:
	// a correct-looking wrong country is worse than no country database.
	for i := 1; i < len(db.v4); i++ {
		if db.v4[i].start <= db.v4[i-1].end {
			return nil, fmt.Errorf("overlapping IPv4 ranges (index %d)", i)
		}
	}
	for i := 1; i < len(db.v6); i++ {
		if !db.v6[i-1].less(db.v6[i]) || db.v6[i].startHi < db.v6[i-1].endHi ||
			(db.v6[i].startHi == db.v6[i-1].endHi && db.v6[i].startLo <= db.v6[i-1].endLo) {
			return nil, fmt.Errorf("overlapping IPv6 ranges (index %d)", i)
		}
	}
	return db, nil
}

func isHeader(row []string) bool {
	return strings.EqualFold(strings.TrimSpace(row[0]), "ip_start") &&
		strings.EqualFold(strings.TrimSpace(row[1]), "ip_end") &&
		strings.EqualFold(strings.TrimSpace(row[2]), "country")
}

// parseAddr accepts only plain addresses without a zone; IPv4-mapped IPv6 is
// normalized to IPv4 so one block is never indexed under two families.
func parseAddr(s string) (netip.Addr, error) {
	ip, err := netip.ParseAddr(strings.TrimSpace(s))
	if err != nil {
		return netip.Addr{}, err
	}
	if ip.Zone() != "" {
		return netip.Addr{}, fmt.Errorf("address %q has a zone", s)
	}
	return ip.Unmap(), nil
}

func validCode(cc string) bool {
	return len(cc) == 2 &&
		cc[0] >= 'A' && cc[0] <= 'Z' &&
		cc[1] >= 'A' && cc[1] <= 'Z'
}

// LookupString is Lookup for text addresses; it reports false rather than an
// error for anything unparsable, so a scraper's junk value cannot fail a page.
func (db *DB) LookupString(s string) (string, bool) {
	ip, err := netip.ParseAddr(strings.TrimSpace(s))
	if err != nil {
		return "", false
	}
	return db.Lookup(ip)
}

func mustPrefix(s string) netip.Prefix {
	p, err := netip.ParsePrefix(s)
	if err != nil {
		panic("geoip: bad reserved prefix " + s)
	}
	return p
}

// ordered reports start <= end.
func (r v6Range) ordered() bool {
	return r.startHi < r.endHi || (r.startHi == r.endHi && r.startLo <= r.endLo)
}

// less orders by start address.
func (r v6Range) less(o v6Range) bool {
	return r.startHi < o.startHi || (r.startHi == o.startHi && r.startLo < o.startLo)
}

// Ranges reports how many v4 and v6 ranges are loaded (startup diagnostics).
func (db *DB) Ranges() (v4, v6 int) {
	if db == nil {
		return 0, 0
	}
	return len(db.v4), len(db.v6)
}

// Lookup returns the ISO-3166 alpha-2 country registered to ip. The second
// result is false for private/reserved addresses, unknown ranges and a nil
// database. IPv4-mapped IPv6 addresses are treated as IPv4.
func (db *DB) Lookup(ip netip.Addr) (string, bool) {
	if db == nil {
		return "", false
	}
	ip = ip.Unmap()
	if !Global(ip) {
		return "", false
	}
	if ip.Is4() {
		a := ip.As4()
		v := binary.BigEndian.Uint32(a[:])
		i := sort.Search(len(db.v4), func(i int) bool { return db.v4[i].start > v }) - 1
		if i < 0 || v > db.v4[i].end {
			return "", false
		}
		return db.codes[db.v4[i].code], true
	}
	a := ip.As16()
	hi, lo := binary.BigEndian.Uint64(a[:8]), binary.BigEndian.Uint64(a[8:])
	i := sort.Search(len(db.v6), func(i int) bool {
		r := db.v6[i]
		return r.startHi > hi || (r.startHi == hi && r.startLo > lo)
	}) - 1
	if i < 0 {
		return "", false
	}
	r := db.v6[i]
	if hi > r.endHi || (hi == r.endHi && lo > r.endLo) {
		return "", false
	}
	return db.codes[r.code], true
}

// Non-global address space. Addr.IsPrivate() only covers RFC1918 and IPv6 ULA,
// so the rest is spelled out: a CGNAT or documentation address must never be
// shown pinned to a country.
//
// This is deliberately the IANA special-purpose registry rather than a coarse
// aggregate: 2001::/23 (for example) also contains assigned global unicast, so
// blocking the whole block would drop real addresses. An address this list
// misses reports no country, which is the honest answer.
var reserved = []netip.Prefix{
	mustPrefix("0.0.0.0/8"),
	mustPrefix("10.0.0.0/8"),
	mustPrefix("100.64.0.0/10"), // CGNAT
	mustPrefix("127.0.0.0/8"),
	mustPrefix("169.254.0.0/16"),
	mustPrefix("172.16.0.0/12"),
	mustPrefix("192.0.0.0/24"),
	mustPrefix("192.0.2.0/24"),
	mustPrefix("192.88.99.0/24"), // 6to4 relay anycast (deprecated)
	mustPrefix("192.168.0.0/16"),
	mustPrefix("198.18.0.0/15"), // benchmarking
	mustPrefix("198.51.100.0/24"),
	mustPrefix("203.0.113.0/24"),
	mustPrefix("224.0.0.0/4"), // multicast
	mustPrefix("240.0.0.0/4"), // reserved + broadcast

	mustPrefix("::/128"),
	mustPrefix("::1/128"),
	mustPrefix("64:ff9b::/96"),    // NAT64
	mustPrefix("64:ff9b:1::/48"),  // local-use NAT64
	mustPrefix("100::/64"),        // discard-only
	mustPrefix("2001::/32"),       // Teredo
	mustPrefix("2001:1::1/128"),   // PCP anycast
	mustPrefix("2001:1::2/128"),   // TURN anycast
	mustPrefix("2001:2::/48"),     // benchmarking
	mustPrefix("2001:3::/32"),     // AMT
	mustPrefix("2001:4:112::/48"), // AS112
	mustPrefix("2001:10::/28"),    // ORCHID
	mustPrefix("2001:20::/28"),    // ORCHIDv2
	mustPrefix("2001:30::/28"),    // Drone Remote ID
	mustPrefix("2001:db8::/32"),   // documentation
	mustPrefix("3fff::/20"),       // documentation (RFC 9637)
	mustPrefix("5f00::/16"),       // segment-routing SIDs
	mustPrefix("fc00::/7"),        // ULA
	mustPrefix("fe80::/10"),       // link-local
	mustPrefix("ff00::/8"),        // multicast
}

// Global reports whether ip is globally routable unicast space, i.e. an
// address a country registration can honestly be shown for.
func Global(ip netip.Addr) bool {
	if !ip.IsValid() {
		return false
	}
	ip = ip.Unmap()
	for _, p := range reserved {
		if p.Contains(ip) {
			return false
		}
	}
	return true
}
