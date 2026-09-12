package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
)

// oaiMessage is an incoming OpenAI chat message. Content is either a string
// or an array of typed parts; both are supported.
type oaiMessage struct {
	Role    string          `json:"role"`
	Content json.RawMessage `json:"content"`
}

// text flattens the message content to plain text.
func (m oaiMessage) text() string {
	if len(m.Content) == 0 {
		return ""
	}
	var s string
	if err := json.Unmarshal(m.Content, &s); err == nil {
		return s
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(m.Content, &parts); err == nil {
		var b strings.Builder
		for _, p := range parts {
			if p.Type == "text" && p.Text != "" {
				if b.Len() > 0 {
					b.WriteString("\n")
				}
				b.WriteString(p.Text)
			}
		}
		return b.String()
	}
	return string(m.Content)
}

// turnPlan is what the bridge sends to HolmesGPT for one request.
type turnPlan struct {
	Ask          string
	SystemPrompt string            // Open WebUI system prompt, passed as additional_system_prompt
	History      []json.RawMessage // HolmesGPT conversation_history to resume from
	UserTurn     int               // 1-based index of the user turn being answered
	Source       string            // stored | rebuilt | new
}

// planTurn decides which HolmesGPT history to resume from.
//
// Open WebUI always sends the whole chat. The bridge keeps HolmesGPT's own
// history (with tool calls) per chat and prefers it, because it lets Holmes
// answer follow-ups from what it already found. Regenerating or editing an
// earlier message shows up as fewer user turns than stored; the stored
// history is then truncated back to that point. If the stored history is
// behind the chat (bridge restarted mid-chat, chat imported), the history is
// rebuilt from the plain messages and Holmes re-derives context.
func planTurn(msgs []oaiMessage, stored []json.RawMessage) turnPlan {
	var p turnPlan
	var userIdx []int
	for i, m := range msgs {
		switch m.Role {
		case "system":
			if i == 0 || p.SystemPrompt == "" {
				p.SystemPrompt = m.text()
			}
		case "user":
			userIdx = append(userIdx, i)
		}
	}

	// The turn being answered is the last user message, unless the chat ends
	// with an assistant message ("continue response").
	last := msgs[len(msgs)-1]
	if last.Role == "user" {
		p.Ask = last.text()
		p.UserTurn = len(userIdx)
	} else {
		p.Ask = "Continue."
		p.UserTurn = len(userIdx) + 1
	}
	if strings.TrimSpace(p.Ask) == "" {
		p.Ask = "Continue."
	}

	storedTurns := 0
	for _, m := range stored {
		if messageRole(m) == "user" {
			storedTurns++
		}
	}

	switch {
	case p.UserTurn == 1 && storedTurns == 0:
		p.Source = "new"
	case storedTurns >= p.UserTurn-1 && storedTurns > 0:
		// Stored history covers every previous turn; drop anything from the
		// turn being (re)answered onwards.
		p.History = truncateBeforeUserTurn(stored, p.UserTurn)
		p.Source = "stored"
	default:
		p.History = rebuildHistory(msgs[:len(msgs)-boolToInt(last.Role == "user")])
		p.Source = "rebuilt"
		if len(p.History) == 0 {
			p.Source = "new"
		}
	}
	return p
}

// truncateBeforeUserTurn returns history up to (excluding) the n-th user
// message, so Holmes re-answers that turn.
func truncateBeforeUserTurn(hist []json.RawMessage, n int) []json.RawMessage {
	seen := 0
	for i, m := range hist {
		if messageRole(m) == "user" {
			seen++
			if seen == n {
				return hist[:i]
			}
		}
	}
	return hist
}

// rebuildHistory converts plain chat messages (without the current ask) into
// a HolmesGPT history. Open WebUI's assistant messages carry the rendered
// tool blocks; strip those so Holmes sees clean prior answers. HolmesGPT
// requires the first entry to be a system message and replaces its content
// with its own prompt, so a placeholder is enough.
func rebuildHistory(msgs []oaiMessage) []json.RawMessage {
	out := []json.RawMessage{}
	for _, m := range msgs {
		if m.Role != "user" && m.Role != "assistant" {
			continue
		}
		content := m.text()
		if m.Role == "assistant" {
			content = stripDetails(content)
		}
		if strings.TrimSpace(content) == "" {
			continue
		}
		b, _ := json.Marshal(map[string]string{"role": m.Role, "content": content})
		out = append(out, b)
	}
	if len(out) == 0 {
		return out
	}
	sys, _ := json.Marshal(map[string]string{"role": "system", "content": "(replaced by HolmesGPT)"})
	return append([]json.RawMessage{sys}, out...)
}

// stripDetails removes <details ...>...</details> blocks.
func stripDetails(s string) string {
	for {
		start := strings.Index(s, "<details")
		if start < 0 {
			return strings.TrimSpace(s)
		}
		end := strings.Index(s[start:], "</details>")
		if end < 0 {
			return strings.TrimSpace(s[:start])
		}
		s = s[:start] + s[start+end+len("</details>"):]
	}
}

// conversationKey identifies the chat. Open WebUI forwards its chat id when
// ENABLE_FORWARD_USER_INFO_HEADERS is on; otherwise the first user message
// plus user id is a stable stand-in for the life of the chat.
func conversationKey(chatID, userID string, msgs []oaiMessage) string {
	chatID = strings.TrimSpace(chatID)
	if chatID != "" && chatID != "local" {
		return chatID
	}
	for _, m := range msgs {
		if m.Role == "user" {
			sum := sha256.Sum256([]byte(userID + "\x00" + m.text()))
			return "anon-" + hex.EncodeToString(sum[:8])
		}
	}
	sum := sha256.Sum256([]byte(userID))
	return "anon-" + hex.EncodeToString(sum[:8])
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
