package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"encoding/xml"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// SMS Backup & Restore XML format
type SMSes struct {
	XMLName  xml.Name `xml:"smses"`
	Count    int      `xml:"count,attr"`
	Messages []SMS    `xml:"sms"`
	MMS      []MMS    `xml:"mms"`
}

type SMS struct {
	Address     string `xml:"address,attr"`
	Date        string `xml:"date,attr"`
	Type        string `xml:"type,attr"` // 1=received, 2=sent
	Body        string `xml:"body,attr"`
	ContactName string `xml:"contact_name,attr"`
	DateSent    string `xml:"date_sent,attr"`
}

type MMS struct {
	Address     string   `xml:"address,attr"`
	Date        string   `xml:"date,attr"`
	MsgBox      string   `xml:"msg_box,attr"` // 1=received, 2=sent
	ContactName string   `xml:"contact_name,attr"`
	DateSent    string   `xml:"date_sent,attr"`
	TextOnly    string   `xml:"text_only,attr"`
	Parts       MMSParts `xml:"parts"`
	Addrs       MMSAddrs `xml:"addrs"`
}

type MMSParts struct {
	Parts []MMSPart `xml:"part"`
}

type MMSPart struct {
	ContentType string `xml:"ct,attr"`
	Name        string `xml:"name,attr"`
	Text        string `xml:"text,attr"`
	Data        string `xml:"data,attr"`
	Seq         string `xml:"seq,attr"`
}

type MMSAddrs struct {
	Addrs []MMSAddr `xml:"addr"`
}

type MMSAddr struct {
	Address string `xml:"address,attr"`
	Type    string `xml:"type,attr"` // 137=from, 151=to, 130=bcc
}

// Unified message type for sorting
type Message struct {
	Timestamp     int64
	IsOutgoing    bool
	Body          string
	ContactName   string
	Address       string // normalized phone number or group key
	IsGroup       bool
	SenderAddress string // for group MMS: the normalized phone of the actual sender
	MediaParts    []MediaPart
}

type MediaPart struct {
	ContentType string
	Filename    string
	Data        []byte
}

// Matrix API types
type MessageContent struct {
	MsgType string `json:"msgtype"`
	Body    string `json:"body"`
}

type MediaContent struct {
	MsgType  string    `json:"msgtype"`
	Body     string    `json:"body"`
	URL      string    `json:"url"`
	Info     MediaInfo `json:"info,omitempty"`
	Filename string    `json:"filename,omitempty"`
}

type MediaInfo struct {
	MimeType string `json:"mimetype"`
	Size     int    `json:"size"`
}

type UploadResponse struct {
	ContentURI string `json:"content_uri"`
}

// RoomMap entry from the bridge database query.
// The JSON file maps normalized phone numbers to room info for DMs,
// and sorted participant sets to room info for groups.
type RoomMapping struct {
	RoomID      string `json:"room_id"`
	DisplayName string `json:"display_name"`
	GhostMXID   string `json:"ghost_mxid"` // the bridge ghost user for this contact (DMs only)
}

type Config struct {
	HomeserverURL string
	ASToken       string
	ServerName    string
	JoshUserID    string
	BotUserID     string
	DryRun        bool
	RoomMap       map[string]RoomMapping // phone or group key -> room mapping
}

var txnCounter atomic.Int64

func nextTxnID() string {
	return fmt.Sprintf("backfill-%d-%d", time.Now().UnixMilli(), txnCounter.Add(1))
}

func encodePathSegment(s string) string {
	return url.PathEscape(s)
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

func matrixRequest(cfg *Config, method, path string, query map[string]string, body interface{}) ([]byte, int, error) {
	var bodyBytes []byte
	if body != nil {
		var err error
		bodyBytes, err = json.Marshal(body)
		if err != nil {
			return nil, 0, fmt.Errorf("marshal body: %w", err)
		}
	}

	reqURL := cfg.HomeserverURL + path
	if len(query) > 0 {
		q := url.Values{}
		for k, v := range query {
			q.Set(k, v)
		}
		reqURL += "?" + q.Encode()
	}

	for attempt := range 5 {
		var bodyReader io.Reader
		if bodyBytes != nil {
			bodyReader = bytes.NewReader(bodyBytes)
		}

		req, err := http.NewRequest(method, reqURL, bodyReader)
		if err != nil {
			return nil, 0, fmt.Errorf("create request: %w", err)
		}
		req.Header.Set("Authorization", "Bearer "+cfg.ASToken)
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return nil, 0, fmt.Errorf("do request: %w", err)
		}

		respBody, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			return nil, resp.StatusCode, fmt.Errorf("read response: %w", err)
		}

		if resp.StatusCode == 429 && attempt < 4 {
			retryAfterMs := 1000
			var errResp map[string]interface{}
			if json.Unmarshal(respBody, &errResp) == nil {
				if ms, ok := errResp["retry_after_ms"].(float64); ok {
					retryAfterMs = int(ms)
				}
			}
			log.Printf("  Rate limited, retrying after %dms (attempt %d/5)", retryAfterMs, attempt+1)
			time.Sleep(time.Duration(retryAfterMs) * time.Millisecond)
			continue
		}

		return respBody, resp.StatusCode, nil
	}

	return nil, 0, fmt.Errorf("exhausted retries for %s %s", method, path)
}

func uploadMedia(cfg *Config, contentType string, data []byte, filename string) (string, error) {
	if cfg.DryRun {
		return "mxc://dry-run/fake-media-id", nil
	}

	q := url.Values{}
	q.Set("filename", filename)
	q.Set("user_id", cfg.BotUserID)
	reqURL := cfg.HomeserverURL + "/_matrix/media/v3/upload?" + q.Encode()

	for attempt := range 5 {
		req, err := http.NewRequest("POST", reqURL, bytes.NewReader(data))
		if err != nil {
			return "", fmt.Errorf("create upload request: %w", err)
		}
		req.Header.Set("Authorization", "Bearer "+cfg.ASToken)
		req.Header.Set("Content-Type", contentType)

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return "", fmt.Errorf("upload request: %w", err)
		}

		respBody, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			return "", fmt.Errorf("read upload response: %w", err)
		}

		if resp.StatusCode == 429 && attempt < 4 {
			retryAfterMs := 1000
			var errResp map[string]interface{}
			if json.Unmarshal(respBody, &errResp) == nil {
				if ms, ok := errResp["retry_after_ms"].(float64); ok {
					retryAfterMs = int(ms)
				}
			}
			log.Printf("  Rate limited on upload, retrying after %dms", retryAfterMs)
			time.Sleep(time.Duration(retryAfterMs) * time.Millisecond)
			continue
		}

		if resp.StatusCode != 200 {
			return "", fmt.Errorf("upload failed (%d): %s", resp.StatusCode, string(respBody))
		}

		var uploadResp UploadResponse
		if err := json.Unmarshal(respBody, &uploadResp); err != nil {
			return "", fmt.Errorf("unmarshal upload response: %w", err)
		}

		return uploadResp.ContentURI, nil
	}

	return "", fmt.Errorf("exhausted retries for media upload")
}

func sendMessage(cfg *Config, roomID, senderUserID string, content interface{}, ts int64) error {
	if cfg.DryRun {
		return nil
	}

	txnID := nextTxnID()
	query := map[string]string{
		"user_id": senderUserID,
		"ts":      strconv.FormatInt(ts, 10),
	}

	respBody, status, err := matrixRequest(cfg, "PUT",
		"/_matrix/client/v3/rooms/"+encodePathSegment(roomID)+"/send/m.room.message/"+txnID, query, content)
	if err != nil {
		return err
	}
	if status != 200 {
		return fmt.Errorf("send message failed (%d): %s", status, string(respBody))
	}
	return nil
}

func parseMessages(data []byte, ownPhone string) ([]Message, error) {
	var smsBackup SMSes
	if err := xml.Unmarshal(data, &smsBackup); err != nil {
		return nil, fmt.Errorf("parse XML: %w", err)
	}

	var messages []Message

	for _, sms := range smsBackup.Messages {
		ts, err := strconv.ParseInt(sms.Date, 10, 64)
		if err != nil {
			log.Printf("WARN: skipping SMS with bad date %q: %v", sms.Date, err)
			continue
		}

		messages = append(messages, Message{
			Timestamp:   ts,
			IsOutgoing:  sms.Type == "2",
			Body:        sms.Body,
			ContactName: sms.ContactName,
			Address:     normalizePhone(sms.Address),
			IsGroup:     false,
		})
	}

	for _, mms := range smsBackup.MMS {
		ts, err := strconv.ParseInt(mms.Date, 10, 64)
		if err != nil {
			log.Printf("WARN: skipping MMS with bad date %q: %v", mms.Date, err)
			continue
		}

		isOutgoing := mms.MsgBox == "2"
		addresses := strings.Split(mms.Address, "~")
		isGroup := len(addresses) > 1

		var normalizedAddrs []string
		for _, a := range addresses {
			norm := normalizePhone(a)
			// Strip Josh's own phone from group keys — the bridge room map
			// only contains ghost (other participant) phones.
			if isGroup && ownPhone != "" && norm == ownPhone {
				continue
			}
			normalizedAddrs = append(normalizedAddrs, norm)
		}
		sort.Strings(normalizedAddrs)

		// If stripping own phone reduced it to 1 participant, it's a DM not a group
		if len(normalizedAddrs) == 1 {
			isGroup = false
		}

		addr := strings.Join(normalizedAddrs, ",")
		if !isGroup {
			addr = normalizedAddrs[0]
		}

		senderAddr := ""
		if isGroup && !isOutgoing {
			for _, a := range mms.Addrs.Addrs {
				if a.Type == "137" {
					senderAddr = normalizePhone(a.Address)
					break
				}
			}
		}

		var body string
		var mediaParts []MediaPart
		for _, part := range mms.Parts.Parts {
			switch {
			case part.ContentType == "application/smil":
				continue
			case part.ContentType == "text/plain":
				if part.Text != "" && part.Text != "null" {
					body = part.Text
				}
			case strings.HasPrefix(part.ContentType, "image/"),
				strings.HasPrefix(part.ContentType, "video/"),
				strings.HasPrefix(part.ContentType, "audio/"):
				if part.Data != "" && part.Data != "null" {
					decoded, err := base64.StdEncoding.DecodeString(part.Data)
					if err != nil {
						log.Printf("WARN: failed to decode media in MMS: %v", err)
						continue
					}
					filename := part.Name
					if filename == "" || filename == "null" {
						filename = "attachment"
					}
					mediaParts = append(mediaParts, MediaPart{
						ContentType: part.ContentType,
						Filename:    filename,
						Data:        decoded,
					})
				}
			}
		}

		msg := Message{
			Timestamp:   ts,
			IsOutgoing:  isOutgoing,
			Body:        body,
			ContactName: mms.ContactName,
			Address:     addr,
			IsGroup:     isGroup,
			MediaParts:  mediaParts,
		}

		if isGroup && !isOutgoing && senderAddr != "" {
			msg.SenderAddress = senderAddr
		}

		messages = append(messages, msg)
	}

	sort.Slice(messages, func(i, j int) bool {
		return messages[i].Timestamp < messages[j].Timestamp
	})

	return messages, nil
}

// Conversation groups messages by address (phone or group key)
type Conversation struct {
	Address      string
	DisplayName  string
	IsGroup      bool
	Messages     []Message
	Participants []string // normalized phone numbers
}

func groupConversations(messages []Message) []Conversation {
	convMap := make(map[string]*Conversation)

	for _, msg := range messages {
		conv, exists := convMap[msg.Address]
		if !exists {
			conv = &Conversation{
				Address: msg.Address,
				IsGroup: msg.IsGroup,
			}

			if msg.IsGroup {
				conv.Participants = strings.Split(msg.Address, ",")
			} else {
				conv.Participants = []string{msg.Address}
			}
			conv.DisplayName = msg.ContactName
			convMap[msg.Address] = conv
		}

		if conv.DisplayName == "(Unknown)" || conv.DisplayName == "" {
			if msg.ContactName != "(Unknown)" && msg.ContactName != "" {
				conv.DisplayName = msg.ContactName
			}
		}

		conv.Messages = append(conv.Messages, msg)
	}

	var conversations []Conversation
	for _, conv := range convMap {
		conversations = append(conversations, *conv)
	}
	sort.Slice(conversations, func(i, j int) bool {
		return conversations[i].Messages[0].Timestamp < conversations[j].Messages[0].Timestamp
	})

	return conversations
}

func backfillConversation(cfg *Config, conv Conversation, roomMapping RoomMapping, idx, total int) error {
	displayName := conv.DisplayName
	if displayName == "" || displayName == "(Unknown)" {
		displayName = conv.Address
	}

	roomID := roomMapping.RoomID
	log.Printf("[%d/%d] Backfilling into %s: %s (%d messages)", idx+1, total, roomID, displayName, len(conv.Messages))

	for i, msg := range conv.Messages {
		var senderUserID string
		if msg.IsOutgoing {
			// Use the bridge bot for outgoing messages. Sending as @josh
			// causes the bridge to relay them as real SMS/RCS texts.
			senderUserID = cfg.BotUserID
		} else if conv.IsGroup && msg.SenderAddress != "" {
			// Group MMS: use the ghost for the actual sender.
			// The bridge ghost MXID format is @gmessages_<prefix>_<participantID>:server
			// but we don't know the prefix/participantID mapping. We need to look
			// up by phone in the room map. For group members that aren't the
			// primary contact, fall back to using the room's ghost.
			found := false
			if mapping, ok := cfg.RoomMap[msg.SenderAddress]; ok && mapping.GhostMXID != "" {
				senderUserID = mapping.GhostMXID
				found = true
			}
			if !found {
				// Fall back to the ghost assigned to this room's mapping
				if roomMapping.GhostMXID != "" {
					senderUserID = roomMapping.GhostMXID
				} else {
					senderUserID = cfg.BotUserID
				}
			}
		} else {
			// 1:1 chat: use the ghost from the room mapping
			if roomMapping.GhostMXID != "" {
				senderUserID = roomMapping.GhostMXID
			} else {
				senderUserID = cfg.BotUserID
			}
		}

		// Send text body if present
		if msg.Body != "" {
			content := MessageContent{
				MsgType: "m.text",
				Body:    msg.Body,
			}
			if err := sendMessage(cfg, roomID, senderUserID, content, msg.Timestamp); err != nil {
				log.Printf("  WARN: failed to send message %d: %v", i, err)
				continue
			}
		}

		// Send media parts
		for _, media := range msg.MediaParts {
			mxcURI, err := uploadMedia(cfg, media.ContentType, media.Data, media.Filename)
			if err != nil {
				log.Printf("  WARN: failed to upload media %s: %v", media.Filename, err)
				continue
			}

			msgType := "m.file"
			if strings.HasPrefix(media.ContentType, "image/") {
				msgType = "m.image"
			} else if strings.HasPrefix(media.ContentType, "video/") {
				msgType = "m.video"
			} else if strings.HasPrefix(media.ContentType, "audio/") {
				msgType = "m.audio"
			}

			content := MediaContent{
				MsgType:  msgType,
				Body:     media.Filename,
				URL:      mxcURI,
				Filename: media.Filename,
				Info: MediaInfo{
					MimeType: media.ContentType,
					Size:     len(media.Data),
				},
			}
			if err := sendMessage(cfg, roomID, senderUserID, content, msg.Timestamp); err != nil {
				log.Printf("  WARN: failed to send media message: %v", err)
			}
		}

		if (i+1)%100 == 0 {
			log.Printf("  Progress: %d/%d messages", i+1, len(conv.Messages))
		}
	}

	log.Printf("  Done: %d messages backfilled", len(conv.Messages))
	return nil
}

func loadRoomMap(path string) (map[string]RoomMapping, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read room map: %w", err)
	}

	var roomMap map[string]RoomMapping
	if err := json.Unmarshal(data, &roomMap); err != nil {
		return nil, fmt.Errorf("parse room map: %w", err)
	}

	return roomMap, nil
}

func main() {
	xmlFile := flag.String("file", "", "Path to SMS Backup & Restore XML file")
	roomMapFile := flag.String("room-map", "", "Path to JSON room map file (phone -> room_id mapping from bridge DB)")
	homeserverURL := flag.String("homeserver", "http://localhost:8008", "Synapse homeserver URL")
	asToken := flag.String("as-token", "", "Appservice access token (as_token from registration.yaml)")
	serverName := flag.String("server-name", "matrix.joshuabell.xyz", "Matrix server name")
	joshUser := flag.String("josh-user", "@josh:matrix.joshuabell.xyz", "Josh's Matrix user ID")
	botUser := flag.String("bot-user", "@gmessagesbot:matrix.joshuabell.xyz", "Bridge bot Matrix user ID")
	joshPhone := flag.String("josh-phone", "", "Josh's phone number (to strip from group keys, e.g. +12244259485)")
	dryRun := flag.Bool("dry-run", false, "Parse and analyze without making API calls")
	flag.Parse()

	if *xmlFile == "" {
		log.Fatal("--file is required")
	}
	if *roomMapFile == "" && !*dryRun {
		log.Fatal("--room-map is required (or use --dry-run)")
	}
	if *asToken == "" && !*dryRun {
		log.Fatal("--as-token is required (or use --dry-run)")
	}

	log.Printf("Loading SMS export from %s...", *xmlFile)
	data, err := os.ReadFile(*xmlFile)
	if err != nil {
		log.Fatalf("Failed to read file: %v", err)
	}

	log.Printf("Parsing messages...")
	messages, err := parseMessages(data, *joshPhone)
	if err != nil {
		log.Fatalf("Failed to parse messages: %v", err)
	}
	log.Printf("Parsed %d messages", len(messages))

	conversations := groupConversations(messages)
	log.Printf("Found %d conversations", len(conversations))

	// Load room map
	var roomMap map[string]RoomMapping
	if *roomMapFile != "" {
		roomMap, err = loadRoomMap(*roomMapFile)
		if err != nil {
			log.Fatalf("Failed to load room map: %v", err)
		}
		log.Printf("Loaded room map with %d entries", len(roomMap))
	}

	// Match conversations to bridge rooms
	matched := 0
	skipped := 0
	totalMessages := 0
	totalMedia := 0
	var matchedConversations []struct {
		Conv    Conversation
		Mapping RoomMapping
	}
	for _, conv := range conversations {
		msgCount := len(conv.Messages)
		mediaCount := 0
		for _, msg := range conv.Messages {
			mediaCount += len(msg.MediaParts)
		}

		if roomMap != nil {
			if mapping, ok := roomMap[conv.Address]; ok {
				matched++
				totalMessages += msgCount
				totalMedia += mediaCount
				matchedConversations = append(matchedConversations, struct {
					Conv    Conversation
					Mapping RoomMapping
				}{conv, mapping})
			} else {
				skipped++
			}
		} else {
			// Dry run without room map — count everything
			totalMessages += msgCount
			totalMedia += mediaCount
		}
	}

	log.Printf("Summary: %d total conversations, %d matched to bridge rooms, %d skipped",
		len(conversations), matched, skipped)
	log.Printf("Will backfill: %d messages, %d media attachments", totalMessages, totalMedia)

	if *dryRun {
		log.Println("\n--- DRY RUN: Conversation breakdown ---")
		for i, conv := range conversations {
			name := conv.DisplayName
			if name == "" || name == "(Unknown)" {
				name = conv.Address
			}
			media := 0
			for _, msg := range conv.Messages {
				media += len(msg.MediaParts)
			}
			earliest := time.UnixMilli(conv.Messages[0].Timestamp).Format("2006-01-02")
			latest := time.UnixMilli(conv.Messages[len(conv.Messages)-1].Timestamp).Format("2006-01-02")

			status := "SKIP"
			roomID := ""
			if roomMap != nil {
				if mapping, ok := roomMap[conv.Address]; ok {
					status = "MATCH"
					roomID = " -> " + mapping.RoomID
				}
			} else {
				status = "?"
			}

			group := ""
			if conv.IsGroup {
				group = " [GROUP]"
			}
			log.Printf("  %d. [%s] %s%s: %d msgs, %d media (%s to %s)%s",
				i+1, status, name, group, len(conv.Messages), media, earliest, latest, roomID)
		}
		log.Println("\nRe-run without --dry-run to perform backfill.")
		return
	}

	cfg := &Config{
		HomeserverURL: *homeserverURL,
		ASToken:       *asToken,
		ServerName:    *serverName,
		JoshUserID:    *joshUser,
		BotUserID:     *botUser,
		DryRun:        false,
		RoomMap:       roomMap,
	}

	log.Println("Starting backfill...")
	succeeded := 0
	failed := 0
	total := len(matchedConversations)
	for i, mc := range matchedConversations {
		if err := backfillConversation(cfg, mc.Conv, mc.Mapping, i, total); err != nil {
			log.Printf("ERROR: conversation %d (%s): %v", i+1, mc.Conv.DisplayName, err)
			failed++
		} else {
			succeeded++
		}
	}

	log.Printf("\nBackfill complete: %d succeeded, %d failed out of %d matched conversations",
		succeeded, failed, total)
}
