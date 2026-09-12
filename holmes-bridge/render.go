package main

import (
	"encoding/json"
	"fmt"
	"html"
	"regexp"
	"strings"
	"time"
)

// Renderer turns HolmesGPT stream events into markdown fragments that Open
// WebUI renders natively:
//
//   - <details type="reasoning" ...>   the model's reasoning ("Thought for 3s")
//   - <details type="tool_calls" ...>  a tool execution with arguments + result
//
// Both are Open WebUI's own conventions (see src/lib/utils/marked/extension.ts
// and ToolCallDisplay.svelte in the Open WebUI repository). Attribute values
// are HTML-escaped JSON, exactly as Open WebUI's backend emits them.
//
// The content stream is append-only, so a tool call is rendered once its
// result is known. Narration HolmesGPT emits between tool calls is streamed
// immediately, which is what tells the user what is happening next.
type Renderer struct {
	maxResultChars int
	lastEvent      time.Time
	wroteBlock     bool
	images         map[string][]ToolImage // tool_call_id -> images the tool returned
}

func NewRenderer(maxResultChars int) *Renderer {
	return &Renderer{maxResultChars: maxResultChars, lastEvent: time.Now(), images: map[string][]ToolImage{}}
}

// HolmesGPT's own UI renders "![caption](tool-image://<tool_call_id>)" by
// looking the image up in the tool call, and its system prompt tells the model
// to write exactly that. Open WebUI knows nothing about the scheme: its image
// URL allowlist rejects it and substitutes the Open WebUI logo, full width.
var toolImageRef = regexp.MustCompile(`!\[([^\]]*)\]\(tool-image://([^)\s]+)\)`)

// resolveImages rewrites tool-image references into something Open WebUI can
// show: the tool's actual image as a data URI when there is one, otherwise
// just the caption. Models tend to "embed" Prometheus query results this way,
// and those carry no image at all.
func (r *Renderer) resolveImages(text string) string {
	if !strings.Contains(text, "tool-image://") {
		return text
	}
	return toolImageRef.ReplaceAllStringFunc(text, func(m string) string {
		sub := toolImageRef.FindStringSubmatch(m)
		caption, id := strings.TrimSpace(sub[1]), sub[2]
		if imgs := r.images[id]; len(imgs) > 0 {
			var b strings.Builder
			for i, img := range imgs {
				if i > 0 {
					b.WriteString("\n\n")
				}
				mime := img.MimeType
				if mime == "" {
					mime = "image/png"
				}
				b.WriteString(fmt.Sprintf("![%s](data:%s;base64,%s)", caption, mime, img.Data))
			}
			return b.String()
		}
		if caption == "" {
			return ""
		}
		return "_" + caption + "_"
	})
}

// Reasoning renders an ai_message event. Returns "" when there is nothing to show.
func (r *Renderer) Reasoning(m AIMessageData) string {
	var b strings.Builder
	elapsed := time.Since(r.lastEvent)
	r.lastEvent = time.Now()

	if m.Reasoning != nil && strings.TrimSpace(*m.Reasoning) != "" {
		secs := int(elapsed.Round(time.Second) / time.Second)
		if secs < 1 {
			secs = 1
		}
		b.WriteString(fmt.Sprintf("<details type=\"reasoning\" done=\"true\" duration=\"%d\">\n", secs))
		b.WriteString(fmt.Sprintf("<summary>Thought for %d second%s</summary>\n", secs, plural(secs)))
		for _, line := range strings.Split(strings.TrimSpace(*m.Reasoning), "\n") {
			b.WriteString("> " + line + "\n")
		}
		b.WriteString("</details>\n")
	}
	if m.Content != nil && strings.TrimSpace(*m.Content) != "" {
		b.WriteString(r.resolveImages(strings.TrimSpace(*m.Content)))
		b.WriteString("\n\n")
	}
	if b.Len() > 0 {
		r.wroteBlock = true
	}
	return b.String()
}

// ToolResult renders a tool_calling_result event and returns the fragment
// plus the (untruncated) textual result for persistence.
func (r *Renderer) ToolResult(t ToolResultData) (fragment string, fullResult string) {
	r.lastEvent = time.Now()
	fullResult = resultText(t.Result.Data)
	if t.Result.Error != nil && *t.Result.Error != "" {
		if fullResult != "" {
			fullResult += "\n"
		}
		fullResult += "error: " + *t.Result.Error
	}

	if len(t.Result.Images) > 0 && t.ToolCallID != "" {
		r.images[t.ToolCallID] = t.Result.Images
	}

	name := toolLabel(t)

	shown := fullResult
	if r.maxResultChars > 0 && len(shown) > r.maxResultChars {
		cut := shown[:r.maxResultChars]
		shown = cut + fmt.Sprintf("\n… [truncated %d characters; full output is stored by holmes-bridge]", len(fullResult)-len(cut))
	}
	if shown == "" {
		shown = "(no output)"
	}

	args := "{}"
	if len(t.Result.Params) > 0 && string(t.Result.Params) != "null" {
		args = string(t.Result.Params)
	}
	resultJSON, _ := json.Marshal(shown)

	var b strings.Builder
	b.WriteString("<details type=\"tool_calls\" done=\"true\"")
	b.WriteString(" id=\"" + attr(t.ToolCallID) + "\"")
	b.WriteString(" name=\"" + attr(name) + "\"")
	b.WriteString(" arguments=\"" + attr(args) + "\"")
	b.WriteString(" result=\"" + attr(string(resultJSON)) + "\"")
	if t.Result.Status != "" && t.Result.Status != "success" {
		status := "failed"
		if t.Result.Status == "no_data" {
			status = "completed" // reads as "done, nothing returned"
		}
		b.WriteString(" status=\"" + status + "\"")
	}
	b.WriteString(">\n<summary>" + html.EscapeString(name) + "</summary>\n</details>\n")
	r.wroteBlock = true
	return b.String(), fullResult
}

// toolLabel is the line Open WebUI shows for a tool step. It leads with the
// tool and toolset so the user can always tell what ran; the free-text
// description (a kubectl filter, a PromQL description, a LogsQL query) follows.
func toolLabel(t ToolResultData) string {
	tool := firstNonEmpty(strings.TrimSpace(t.ToolName), strings.TrimSpace(t.Name))
	label := tool
	if ts := strings.TrimSpace(t.ToolsetName); ts != "" && ts != tool {
		label += " (" + ts + ")"
	}
	if label == "" {
		label = "tool"
	}
	if desc := oneLine(t.Description, 120); desc != "" && desc != tool {
		label += ": " + desc
	}
	return label
}

// Answer renders the final analysis.
func (r *Renderer) Answer(text string) string {
	text = r.resolveImages(strings.TrimSpace(text))
	if text == "" {
		return ""
	}
	if r.wroteBlock {
		return "\n" + text
	}
	return text
}

// Note renders a short informational line (e.g. history compaction).
func (r *Renderer) Note(text string) string {
	r.wroteBlock = true
	return "_" + oneLine(text, 300) + "_\n\n"
}

// Error renders a failure so it is visible in the chat.
func (r *Renderer) Error(text string) string {
	return "\n> ⚠️ **HolmesGPT error:** " + oneLine(text, 2000) + "\n"
}

// attr escapes a value for use inside a double-quoted HTML attribute. Open
// WebUI parses attributes with /(\w+)="(.*?)"/ (no dotall), so newlines are
// escaped as entities too.
func attr(s string) string {
	s = html.EscapeString(s)
	s = strings.ReplaceAll(s, "\n", "&#10;")
	s = strings.ReplaceAll(s, "\r", "")
	return s
}

func oneLine(s string, max int) string {
	s = strings.Join(strings.Fields(s), " ")
	if max > 0 && len(s) > max {
		return s[:max-1] + "…"
	}
	return s
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

// resultText renders a tool result's data as text: strings verbatim,
// anything else as indented JSON.
func resultText(data json.RawMessage) string {
	if len(data) == 0 || string(data) == "null" {
		return ""
	}
	var s string
	if err := json.Unmarshal(data, &s); err == nil {
		return s
	}
	var v any
	if err := json.Unmarshal(data, &v); err != nil {
		return string(data)
	}
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return string(data)
	}
	return string(b)
}
