package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// HolmesClient talks to HolmesGPT's HTTP API (POST /api/chat with stream=true).
type HolmesClient struct {
	baseURL string
	http    *http.Client
	timeout time.Duration
}

func NewHolmesClient(baseURL string, timeout time.Duration) *HolmesClient {
	return &HolmesClient{
		baseURL: baseURL,
		timeout: timeout,
		// No client-level timeout: the request context carries the deadline so
		// that a long-running stream is not cut mid-answer.
		http: &http.Client{},
	}
}

// ChatRequest mirrors the fields of HolmesGPT's ChatRequest that the bridge uses.
type ChatRequest struct {
	Ask                    string            `json:"ask"`
	ConversationHistory    []json.RawMessage `json:"conversation_history,omitempty"`
	AdditionalSystemPrompt string            `json:"additional_system_prompt,omitempty"`
	Stream                 bool              `json:"stream"`
	ConversationID         string            `json:"conversation_id,omitempty"`
	UserID                 string            `json:"user_id,omitempty"`
	RequestSource          string            `json:"request_source,omitempty"`
}

// Event is one server-sent event from HolmesGPT.
type Event struct {
	Name string
	Data json.RawMessage
}

// Event names emitted by HolmesGPT (holmes/utils/stream.py).
const (
	evAnswerEnd        = "ai_answer_end"
	evStartTool        = "start_tool_calling"
	evToolResult       = "tool_calling_result"
	evError            = "error"
	evAIMessage        = "ai_message"
	evApprovalRequired = "approval_required"
	evTokenCount       = "token_count"
	evCompactionStart  = "conversation_history_compaction_start"
	evCompacted        = "conversation_history_compacted"
)

// Payload shapes of the events above.
type (
	StartToolData struct {
		ToolName string `json:"tool_name"`
		ID       string `json:"id"`
	}
	ToolResultData struct {
		ToolCallID  string `json:"tool_call_id"`
		ToolName    string `json:"tool_name"`
		Name        string `json:"name"`
		Description string `json:"description"`
		ToolsetName string `json:"toolset_name"`
		Result      struct {
			Status         string          `json:"status"`
			Error          *string         `json:"error"`
			ReturnCode     *int            `json:"return_code"`
			Data           json.RawMessage `json:"data"`
			URL            *string         `json:"url"`
			Invocation     *string         `json:"invocation"`
			Params         json.RawMessage `json:"params"`
			ElapsedSeconds *float64        `json:"elapsed_seconds"`
			// Images returned by the tool (Grafana renders), base64 encoded.
			Images []ToolImage `json:"images"`
		} `json:"result"`
	}
	ToolImage struct {
		MimeType string `json:"mimeType"`
		Data     string `json:"data"`
	}
	AIMessageData struct {
		Content   *string `json:"content"`
		Reasoning *string `json:"reasoning"`
	}
	AnswerEndData struct {
		Analysis            *string           `json:"analysis"`
		ConversationHistory []json.RawMessage `json:"conversation_history"`
		Metadata            struct {
			Usage struct {
				PromptTokens     int `json:"prompt_tokens"`
				CompletionTokens int `json:"completion_tokens"`
				TotalTokens      int `json:"total_tokens"`
				CachedTokens     int `json:"cached_tokens"`
			} `json:"usage"`
			Costs struct {
				TotalCost float64 `json:"total_cost"`
			} `json:"costs"`
		} `json:"metadata"`
	}
	ErrorData struct {
		Description string `json:"description"`
		Msg         string `json:"msg"`
		ErrorCode   int    `json:"error_code"`
	}
)

// ErrHolmes is returned when HolmesGPT answers with a non-2xx status.
type ErrHolmes struct {
	Status int
	Body   string
}

func (e *ErrHolmes) Error() string {
	return fmt.Sprintf("holmes returned HTTP %d: %s", e.Status, holmesErrorMessage(e.Body))
}

// holmesErrorMessage pulls the human-readable part out of a FastAPI error
// body ({"detail": "..."} or {"detail": [{"msg": "..."}]}), falling back to
// the raw body.
func holmesErrorMessage(body string) string {
	var v struct {
		Detail json.RawMessage `json:"detail"`
	}
	if err := json.Unmarshal([]byte(body), &v); err != nil || len(v.Detail) == 0 {
		return body
	}
	var s string
	if json.Unmarshal(v.Detail, &s) == nil {
		return s
	}
	var items []struct {
		Msg string `json:"msg"`
	}
	if json.Unmarshal(v.Detail, &items) == nil && len(items) > 0 && items[0].Msg != "" {
		msgs := make([]string, 0, len(items))
		for _, it := range items {
			if it.Msg != "" {
				msgs = append(msgs, it.Msg)
			}
		}
		return strings.Join(msgs, "; ")
	}
	return body
}

// Chat streams a HolmesGPT chat. onEvent is called for every SSE event in
// order; returning an error aborts the stream.
func (c *HolmesClient) Chat(ctx context.Context, req ChatRequest, onEvent func(Event) error) error {
	req.Stream = true
	body, err := json.Marshal(req)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/api/chat", bytes.NewReader(body))
	if err != nil {
		return err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "text/event-stream")

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode/100 != 2 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<10))
		return &ErrHolmes{Status: resp.StatusCode, Body: strings.TrimSpace(string(b))}
	}

	return readSSE(resp.Body, onEvent)
}

// readSSE parses a text/event-stream body. HolmesGPT emits
// "event: <name>\ndata: <json>\n\n" records; data may in principle span
// several lines, which the SSE spec joins with "\n".
func readSSE(r io.Reader, onEvent func(Event) error) error {
	sc := bufio.NewScanner(r)
	// Tool results can be large; allow generous lines.
	sc.Buffer(make([]byte, 0, 64<<10), 64<<20)

	var name string
	var data []string
	flush := func() error {
		if name == "" && len(data) == 0 {
			return nil
		}
		ev := Event{Name: name, Data: json.RawMessage(strings.Join(data, "\n"))}
		name, data = "", nil
		if ev.Name == "" {
			ev.Name = "message"
		}
		return onEvent(ev)
	}
	for sc.Scan() {
		line := sc.Text()
		switch {
		case line == "":
			if err := flush(); err != nil {
				return err
			}
		case strings.HasPrefix(line, ":"):
			// comment / keepalive
		case strings.HasPrefix(line, "event:"):
			name = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
		case strings.HasPrefix(line, "data:"):
			data = append(data, strings.TrimPrefix(strings.TrimPrefix(line, "data:"), " "))
		}
	}
	if err := sc.Err(); err != nil {
		return fmt.Errorf("read stream: %w", err)
	}
	return flush()
}

// Model returns HolmesGPT's /api/model payload, used for readiness.
func (c *HolmesClient) Model(ctx context.Context) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+"/api/model", nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return nil, errors.New("holmes /api/model returned " + resp.Status)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out, nil
}
