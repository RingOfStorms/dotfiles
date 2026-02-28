package main

// generate-room-map generates a JSON room map for the SMS backfill script.
//
// It queries:
//   - The mautrix-gmessages bridge database (via psql inside the container)
//     for ghost phone numbers and portal data
//   - The Synapse admin API for group room membership
//
// Output: JSON mapping of normalized phone (DMs) or sorted comma-separated
// phones (groups) to { room_id, display_name, ghost_mxid }.
//
// Usage:
//   go run generate-room-map.go \
//     --admin-token <synapse-admin-token> \
//     --homeserver http://10.0.0.6:8008 \
//     --psql-cmd 'sudo nixos-container run matrix -- su -s /bin/sh postgres -c'
//
// The psql-cmd flag specifies how to run psql commands inside the container.
// The command will be invoked as: <psql-cmd> "psql -t -A mautrix_gmessages -c '<SQL>'"

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"sort"
	"strings"
)

type RoomMapping struct {
	RoomID      string `json:"room_id"`
	DisplayName string `json:"display_name"`
	GhostMXID   string `json:"ghost_mxid"` // primary ghost for DMs, empty for groups
}

type GhostInfo struct {
	ID    string
	Name  string
	Phone string // normalized phone
	MXID  string // @gmessages_<id>:<server>
}

type PortalInfo struct {
	ID          string
	MXID        string // room ID
	OtherUserID string // ghost ID for DMs, empty for groups
	Name        string
}

type AdminRoomListResponse struct {
	Rooms     []AdminRoom `json:"rooms"`
	TotalRooms int        `json:"total_rooms"`
	NextBatch  int        `json:"next_batch"`
}

type AdminRoom struct {
	RoomID        string `json:"room_id"`
	Name          string `json:"name"`
	JoinedMembers int    `json:"joined_members"`
}

type AdminMembersResponse struct {
	Members []string `json:"members"`
	Total   int      `json:"total"`
}

func normalizePhone(phone string) string {
	var digits []byte
	for _, c := range phone {
		if c >= '0' && c <= '9' {
			digits = append(digits, byte(c))
		}
	}
	s := string(digits)
	if len(s) == 10 {
		s = "1" + s
	}
	return "+" + s
}

func runPsql(psqlCmd, db, sql string) (string, error) {
	fullSQL := fmt.Sprintf("psql -t -A %s -c %q", db, sql)
	parts := strings.Fields(psqlCmd)
	args := append(parts[1:], fullSQL)
	cmd := exec.Command(parts[0], args...)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("psql command failed: %w", err)
	}
	return strings.TrimSpace(string(out)), nil
}

func synapseAdminRequest(homeserver, token, path string) ([]byte, error) {
	reqURL := homeserver + path
	req, err := http.NewRequest("GET", reqURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("admin API %s returned %d: %s", path, resp.StatusCode, string(body))
	}
	return body, nil
}

func getRoomMembers(homeserver, token, roomID string) ([]string, error) {
	encoded := url.PathEscape(roomID)
	body, err := synapseAdminRequest(homeserver, token, "/_synapse/admin/v1/rooms/"+encoded+"/members")
	if err != nil {
		return nil, err
	}
	var resp AdminMembersResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("unmarshal members: %w", err)
	}
	return resp.Members, nil
}

func main() {
	adminToken := flag.String("admin-token", "", "Synapse admin access token")
	homeserver := flag.String("homeserver", "http://10.0.0.6:8008", "Synapse homeserver URL")
	psqlCmd := flag.String("psql-cmd", "sudo nixos-container run matrix -- su -s /bin/sh postgres -c", "Command prefix to run psql inside container")
	serverName := flag.String("server-name", "matrix.joshuabell.xyz", "Matrix server name")
	flag.Parse()

	if *adminToken == "" {
		log.Fatal("--admin-token is required")
	}

	// Step 1: Load all ghosts with phone numbers from the bridge DB
	log.Println("Loading ghosts from bridge database...")
	ghostSQL := `SELECT id || '|' || COALESCE(name, '') || '|' || COALESCE(metadata->>'phone', '') FROM ghost WHERE metadata->>'phone' IS NOT NULL AND metadata->>'phone' != ''`
	ghostOutput, err := runPsql(*psqlCmd, "mautrix_gmessages", ghostSQL)
	if err != nil {
		log.Fatalf("Failed to load ghosts: %v", err)
	}

	ghostByID := make(map[string]*GhostInfo)   // ghost ID -> info
	ghostByPhone := make(map[string]*GhostInfo) // normalized phone -> info

	for _, line := range strings.Split(ghostOutput, "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "|", 3)
		if len(parts) != 3 {
			continue
		}
		phone := normalizePhone(parts[2])
		ghost := &GhostInfo{
			ID:    parts[0],
			Name:  parts[1],
			Phone: phone,
			MXID:  fmt.Sprintf("@gmessages_%s:%s", parts[0], *serverName),
		}
		ghostByID[ghost.ID] = ghost
		ghostByPhone[phone] = ghost
	}
	log.Printf("Loaded %d ghosts with phone numbers", len(ghostByID))

	// Step 2: Load all portals from the bridge DB
	log.Println("Loading portals from bridge database...")
	portalSQL := `SELECT id || '|' || COALESCE(mxid, '') || '|' || COALESCE(other_user_id, '') || '|' || COALESCE(name, '') FROM portal WHERE mxid IS NOT NULL AND mxid != ''`
	portalOutput, err := runPsql(*psqlCmd, "mautrix_gmessages", portalSQL)
	if err != nil {
		log.Fatalf("Failed to load portals: %v", err)
	}

	var dmPortals []PortalInfo
	var groupPortals []PortalInfo

	for _, line := range strings.Split(portalOutput, "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "|", 4)
		if len(parts) != 4 {
			continue
		}
		portal := PortalInfo{
			ID:          parts[0],
			MXID:        parts[1],
			OtherUserID: parts[2],
			Name:        parts[3],
		}
		if portal.OtherUserID != "" {
			dmPortals = append(dmPortals, portal)
		} else {
			groupPortals = append(groupPortals, portal)
		}
	}
	log.Printf("Loaded %d DM portals, %d group portals", len(dmPortals), len(groupPortals))

	roomMap := make(map[string]RoomMapping)

	// Step 3: Map DM portals by phone number
	for _, portal := range dmPortals {
		ghost, ok := ghostByID[portal.OtherUserID]
		if !ok || ghost.Phone == "" {
			log.Printf("  WARN: DM portal %s (room %s) has no ghost phone for other_user_id=%s", portal.ID, portal.MXID, portal.OtherUserID)
			continue
		}

		displayName := portal.Name
		if displayName == "" {
			displayName = ghost.Name
		}
		if displayName == "" {
			displayName = ghost.Phone
		}

		roomMap[ghost.Phone] = RoomMapping{
			RoomID:      portal.MXID,
			DisplayName: displayName,
			GhostMXID:   ghost.MXID,
		}
	}
	log.Printf("Mapped %d DM conversations", len(roomMap))

	// Step 4: Map group portals by querying Synapse for room members
	log.Println("Resolving group chat members via Synapse admin API...")
	groupsMapped := 0
	groupsSkipped := 0

	for _, portal := range groupPortals {
		members, err := getRoomMembers(*homeserver, *adminToken, portal.MXID)
		if err != nil {
			log.Printf("  WARN: failed to get members for group %s (%s): %v", portal.Name, portal.MXID, err)
			groupsSkipped++
			continue
		}

		// Extract ghost member phones
		var phones []string
		for _, member := range members {
			// Skip non-ghost members (josh, bot)
			if !strings.HasPrefix(member, "@gmessages_") {
				continue
			}
			// Extract ghost ID: @gmessages_<id>:<server> -> <id>
			atIdx := strings.Index(member, ":")
			if atIdx < 0 {
				continue
			}
			ghostID := strings.TrimPrefix(member[:atIdx], "@gmessages_")

			ghost, ok := ghostByID[ghostID]
			if !ok || ghost.Phone == "" {
				log.Printf("  WARN: group %s member ghost %s has no phone number", portal.Name, ghostID)
				continue
			}
			phones = append(phones, ghost.Phone)
		}

		if len(phones) < 2 {
			log.Printf("  WARN: group %s (%s) has only %d phone members, skipping", portal.Name, portal.MXID, len(phones))
			groupsSkipped++
			continue
		}

		// Sort phones to create the same key format as the SMS export
		sort.Strings(phones)
		groupKey := strings.Join(phones, ",")

		roomMap[groupKey] = RoomMapping{
			RoomID:      portal.MXID,
			DisplayName: portal.Name,
			GhostMXID:   "", // no single ghost for groups
		}
		groupsMapped++
	}
	log.Printf("Mapped %d group conversations (%d skipped)", groupsMapped, groupsSkipped)

	// Output JSON
	output, err := json.MarshalIndent(roomMap, "", "  ")
	if err != nil {
		log.Fatalf("Failed to marshal room map: %v", err)
	}

	fmt.Println(string(output))
	log.Printf("Total room map: %d entries (%d DMs + %d groups)", len(roomMap), len(roomMap)-groupsMapped, groupsMapped)
}
