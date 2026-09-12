package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Server implements the OpenAI-compatible API plus a few read-only endpoints
// over the SQLite store.
type Server struct {
	cfg         Config
	store       *Store
	holmes      *HolmesClient
	log         *slog.Logger
	hiddenTools map[string]bool // tool names persisted but not shown in the chat
}

func NewServer(cfg Config, store *Store, holmes *HolmesClient, log *slog.Logger) *Server {
	hidden := map[string]bool{}
	for _, t := range cfg.HiddenTools {
		if t = strings.TrimSpace(t); t != "" {
			hidden[t] = true
		}
	}
	return &Server{cfg: cfg, store: store, holmes: holmes, log: log, hiddenTools: hidden}
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /readyz", s.readyz)
	mux.HandleFunc("GET /", s.index)

	mux.HandleFunc("GET /v1/models", s.auth(s.models))
	mux.HandleFunc("GET /v1/models/{id}", s.auth(s.model))
	mux.HandleFunc("POST /v1/chat/completions", s.auth(s.chatCompletions))

	mux.HandleFunc("GET /api/conversations", s.listConversations)
	mux.HandleFunc("GET /api/conversations/{id}", s.getConversation)
	mux.HandleFunc("GET /api/requests", s.listRequests)
	mux.HandleFunc("GET /api/requests/{id}/tool_calls", s.listToolCalls)
	return logRequests(s.log, mux)
}

func logRequests(log *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		if r.URL.Path == "/healthz" || r.URL.Path == "/readyz" {
			return
		}
		log.Debug("http", "method", r.Method, "path", r.URL.Path, "ms", time.Since(start).Milliseconds())
	})
}

// auth enforces BRIDGE_API_KEY when configured. Open WebUI always sends a
// bearer token; by default any value is accepted.
func (s *Server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.cfg.APIKey != "" {
			got := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer"))
			if got != s.cfg.APIKey {
				writeOpenAIError(w, http.StatusUnauthorized, "invalid API key", "invalid_api_key")
				return
			}
		}
		next(w, r)
	}
}

// ---------------------------------------------------------------------------
// Health / index
// ---------------------------------------------------------------------------

func (s *Server) healthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) readyz(w http.ResponseWriter, r *http.Request) {
	if err := s.store.Ping(r.Context()); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "db unavailable", "error": err.Error()})
		return
	}
	if _, err := s.holmes.Model(r.Context()); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "holmes unavailable", "error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) index(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	st, err := s.store.Stats(r.Context())
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"service": "holmes-bridge",
		"model":   s.cfg.ModelID,
		"holmes":  s.cfg.HolmesURL,
		"stats":   st,
		"endpoints": []string{
			"GET  /v1/models", "POST /v1/chat/completions",
			"GET  /api/conversations", "GET  /api/conversations/{id}",
			"GET  /api/requests?conversation_id=&limit=", "GET  /api/requests/{id}/tool_calls",
			"GET  /healthz", "GET  /readyz",
		},
	})
}

// ---------------------------------------------------------------------------
// OpenAI: models
// ---------------------------------------------------------------------------

func (s *Server) modelObject() map[string]any {
	return map[string]any{
		"id":       s.cfg.ModelID,
		"object":   "model",
		"created":  0,
		"owned_by": "holmes-bridge",
		"name":     s.cfg.ModelName,
	}
}

func (s *Server) models(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"object": "list", "data": []any{s.modelObject()}})
}

func (s *Server) model(w http.ResponseWriter, r *http.Request) {
	if r.PathValue("id") != s.cfg.ModelID {
		writeOpenAIError(w, http.StatusNotFound, "model not found", "model_not_found")
		return
	}
	writeJSON(w, http.StatusOK, s.modelObject())
}

// ---------------------------------------------------------------------------
// OpenAI: chat completions
// ---------------------------------------------------------------------------

type chatCompletionRequest struct {
	Model    string       `json:"model"`
	Messages []oaiMessage `json:"messages"`
	Stream   bool         `json:"stream"`
	User     string       `json:"user"`
}

type usage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

func (s *Server) chatCompletions(w http.ResponseWriter, r *http.Request) {
	var req chatCompletionRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32<<20)).Decode(&req); err != nil {
		writeOpenAIError(w, http.StatusBadRequest, "invalid JSON body: "+err.Error(), "invalid_request_error")
		return
	}
	if len(req.Messages) == 0 {
		writeOpenAIError(w, http.StatusBadRequest, "messages must not be empty", "invalid_request_error")
		return
	}

	chatID := r.Header.Get("X-OpenWebUI-Chat-Id")
	userID := firstNonEmpty(r.Header.Get("X-OpenWebUI-User-Id"), req.User)
	userName := firstNonEmpty(r.Header.Get("X-OpenWebUI-User-Name"), r.Header.Get("X-OpenWebUI-User-Email"))
	convID := conversationKey(chatID, userID, req.Messages)

	ctx := r.Context()
	var stored []json.RawMessage
	if c, err := s.store.GetConversation(ctx, convID); err == nil {
		stored = c.History
	} else if !errors.Is(err, errNotFound) {
		s.log.Error("load conversation", "id", convID, "err", err)
	}

	plan := planTurn(req.Messages, stored)
	reqID, err := s.store.CreateRequest(ctx, convID, plan.Ask, s.cfg.ModelID)
	if err != nil {
		s.log.Error("create request row", "err", err)
		writeOpenAIError(w, http.StatusInternalServerError, "persistence failure: "+err.Error(), "server_error")
		return
	}
	log := s.log.With("conversation", convID, "request", reqID, "turn", plan.UserTurn, "history", plan.Source)
	log.Info("chat", "ask", oneLine(plan.Ask, 120), "stream", req.Stream, "user", userName)

	completionID := fmt.Sprintf("chatcmpl-%d-%d", reqID, time.Now().UnixNano())
	var out outputSink
	if req.Stream {
		out = newSSESink(w, completionID, s.cfg.ModelID)
	} else {
		out = &bufferSink{}
	}

	res := s.runTurn(ctx, log, plan, convID, userID, userName, reqID, out)

	if req.Stream {
		out.(*sseSink).finish(res.usage, res.finishReason)
		return
	}
	body := out.(*bufferSink).String()
	if res.err != nil && body == "" {
		writeOpenAIError(w, http.StatusBadGateway, res.err.Error(), "server_error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id":      completionID,
		"object":  "chat.completion",
		"created": time.Now().Unix(),
		"model":   s.cfg.ModelID,
		"choices": []any{map[string]any{
			"index":         0,
			"message":       map[string]any{"role": "assistant", "content": body},
			"finish_reason": res.finishReason,
		}},
		"usage": res.usage,
	})
}

type turnResult struct {
	usage        usage
	finishReason string
	err          error
}

// runTurn drives one HolmesGPT chat, streaming rendered fragments into out and
// persisting everything as it goes.
func (s *Server) runTurn(ctx context.Context, log *slog.Logger, plan turnPlan, convID, userID, userName string, reqID int64, out outputSink) turnResult {
	started := time.Now()
	rend := NewRenderer(s.cfg.ToolResultMaxChars)
	outcome := RequestOutcome{Status: "failed", Started: started}
	var answer strings.Builder
	seq := 0
	answered := false

	// Keepalive comments so idle proxies do not drop a quiet stream while the
	// LLM is thinking.
	stopPing := out.keepalive(15 * time.Second)
	defer stopPing()

	// Persistence must survive the client going away, so every write gets its
	// own short-lived context detached from the request.
	persist := func(name string, fn func(ctx context.Context) error) {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := fn(ctx); err != nil {
			log.Error("persist "+name, "err", err)
		}
	}

	hreq := ChatRequest{
		Ask:                    plan.Ask,
		ConversationHistory:    plan.History,
		AdditionalSystemPrompt: joinPrompts(s.cfg.SystemPrompt, plan.SystemPrompt),
		ConversationID:         convID,
		UserID:                 userID,
		RequestSource:          "open-webui",
	}

	err := s.holmes.Chat(ctx, hreq, func(ev Event) error {
		switch ev.Name {
		case evAIMessage:
			var m AIMessageData
			if err := json.Unmarshal(ev.Data, &m); err != nil {
				log.Warn("bad ai_message payload", "err", err)
				return nil
			}
			return out.write(rend.Reasoning(m))

		case evStartTool:
			var st StartToolData
			if err := json.Unmarshal(ev.Data, &st); err != nil {
				return nil
			}
			seq++
			outcome.ToolCallCount = seq
			log.Info("tool start", "tool", st.ToolName, "id", st.ID)
			persist("tool start", func(ctx context.Context) error {
				return s.store.StartToolCall(ctx, reqID, seq, st.ID, st.ToolName)
			})
			return nil

		case evToolResult:
			var tr ToolResultData
			if err := json.Unmarshal(ev.Data, &tr); err != nil {
				log.Warn("bad tool_calling_result payload", "err", err)
				return nil
			}
			frag, full := rend.ToolResult(tr)
			log.Info("tool result", "tool", tr.ToolName, "status", tr.Result.Status, "bytes", len(full), "desc", oneLine(tr.Description, 100))
			persist("tool result", func(ctx context.Context) error {
				return s.store.FinishToolCall(ctx, reqID, seq, tr, full)
			})
			if s.hiddenTools[tr.ToolName] {
				return nil
			}
			return out.write(frag)

		case evAnswerEnd:
			var ae AnswerEndData
			if err := json.Unmarshal(ev.Data, &ae); err != nil {
				return fmt.Errorf("bad ai_answer_end payload: %w", err)
			}
			answered = true
			text := ""
			if ae.Analysis != nil {
				text = *ae.Analysis
			}
			answer.WriteString(text)
			outcome.Status = "completed"
			outcome.Answer = text
			outcome.PromptTokens = ae.Metadata.Usage.PromptTokens
			outcome.CompletionTokens = ae.Metadata.Usage.CompletionTokens
			outcome.TotalTokens = ae.Metadata.Usage.TotalTokens
			outcome.CachedTokens = ae.Metadata.Usage.CachedTokens
			outcome.CostUSD = ae.Metadata.Costs.TotalCost
			if len(ae.ConversationHistory) > 0 {
				persist("conversation", func(ctx context.Context) error {
					return s.store.SaveConversation(ctx, convID, userID, userName, plan.Ask, ae.ConversationHistory)
				})
			}
			return out.write(rend.Answer(text))

		case evApprovalRequired:
			// Tool approval is disabled in the request; treat as a terminal state.
			answered = true
			outcome.Status = "completed"
			outcome.Error = "holmes asked for tool approval, which the bridge does not support"
			return out.write(rend.Note("HolmesGPT paused for tool approval; approvals are not supported through this bridge."))

		case evError:
			var e ErrorData
			_ = json.Unmarshal(ev.Data, &e)
			msg := firstNonEmpty(e.Description, e.Msg, string(ev.Data))
			outcome.Error = msg
			return fmt.Errorf("holmes: %s", msg)

		case evCompactionStart:
			return out.write(rend.Note("Compacting conversation history…"))
		case evCompacted:
			return out.write(rend.Note("Conversation history compacted."))
		case evTokenCount:
			return nil
		default:
			log.Debug("unhandled event", "event", ev.Name)
			return nil
		}
	})

	res := turnResult{finishReason: "stop"}
	switch {
	case err == nil && answered:
	case err == nil && !answered:
		err = errors.New("holmes stream ended without an answer")
		fallthrough
	default:
		if errors.Is(ctx.Err(), context.Canceled) {
			outcome.Status = "cancelled"
			outcome.Error = "client disconnected"
			log.Warn("request cancelled by client", "elapsed_ms", time.Since(started).Milliseconds())
		} else {
			outcome.Status = "failed"
			if outcome.Error == "" {
				outcome.Error = err.Error()
			}
			log.Error("holmes chat failed", "err", err)
			_ = out.write(rend.Error(outcome.Error))
		}
		res.err = err
	}

	res.usage = usage{PromptTokens: outcome.PromptTokens, CompletionTokens: outcome.CompletionTokens, TotalTokens: outcome.TotalTokens}
	persist("request outcome", func(ctx context.Context) error {
		return s.store.FinishRequest(ctx, reqID, outcome)
	})
	log.Info("done", "status", outcome.Status, "tools", outcome.ToolCallCount, "tokens", outcome.TotalTokens,
		"cost_usd", outcome.CostUSD, "elapsed_ms", time.Since(started).Milliseconds())
	return res
}

// ---------------------------------------------------------------------------
// Output sinks
// ---------------------------------------------------------------------------

type outputSink interface {
	write(fragment string) error
	keepalive(every time.Duration) (stop func())
}

// bufferSink collects the whole answer for non-streaming responses.
type bufferSink struct{ strings.Builder }

func (b *bufferSink) write(f string) error                  { b.WriteString(f); return nil }
func (b *bufferSink) keepalive(time.Duration) (stop func()) { return func() {} }

// sseSink writes OpenAI chat.completion.chunk events.
type sseSink struct {
	w       http.ResponseWriter
	flusher http.Flusher
	mu      sync.Mutex
	id      string
	model   string
	created int64
	started bool
	closed  bool
}

func newSSESink(w http.ResponseWriter, id, model string) *sseSink {
	f, _ := w.(http.Flusher)
	return &sseSink{w: w, flusher: f, id: id, model: model, created: time.Now().Unix()}
}

func (s *sseSink) header() {
	if s.started {
		return
	}
	s.started = true
	h := s.w.Header()
	h.Set("Content-Type", "text/event-stream; charset=utf-8")
	h.Set("Cache-Control", "no-cache")
	h.Set("Connection", "keep-alive")
	h.Set("X-Accel-Buffering", "no")
	s.w.WriteHeader(http.StatusOK)
	s.flush()
}

func (s *sseSink) flush() {
	if s.flusher != nil {
		s.flusher.Flush()
	}
}

func (s *sseSink) chunk(delta map[string]any, finish *string, u *usage) error {
	choice := map[string]any{"index": 0, "delta": delta, "finish_reason": finish}
	payload := map[string]any{
		"id": s.id, "object": "chat.completion.chunk", "created": s.created, "model": s.model,
		"choices": []any{choice},
	}
	if u != nil {
		payload["usage"] = u
	}
	b, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(s.w, "data: %s\n\n", b)
	s.flush()
	return err
}

func (s *sseSink) write(fragment string) error {
	if fragment == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	if !s.started {
		s.header()
		if err := s.chunk(map[string]any{"role": "assistant", "content": ""}, nil, nil); err != nil {
			return err
		}
	}
	return s.chunk(map[string]any{"content": fragment}, nil, nil)
}

func (s *sseSink) finish(u usage, reason string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	s.closed = true
	if !s.started {
		s.header()
		_ = s.chunk(map[string]any{"role": "assistant", "content": ""}, nil, nil)
	}
	_ = s.chunk(map[string]any{}, &reason, &u)
	_, _ = fmt.Fprint(s.w, "data: [DONE]\n\n")
	s.flush()
}

func (s *sseSink) keepalive(every time.Duration) (stop func()) {
	done := make(chan struct{})
	go func() {
		t := time.NewTicker(every)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				s.mu.Lock()
				if !s.closed {
					if !s.started {
						s.header()
					}
					_, _ = fmt.Fprint(s.w, ": ping\n\n")
					s.flush()
				}
				s.mu.Unlock()
			}
		}
	}()
	return func() { close(done) }
}

// ---------------------------------------------------------------------------
// Read-only API over the store
// ---------------------------------------------------------------------------

func (s *Server) listConversations(w http.ResponseWriter, r *http.Request) {
	list, err := s.store.ListConversations(r.Context(), queryLimit(r, 50))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"conversations": list})
}

func (s *Server) getConversation(w http.ResponseWriter, r *http.Request) {
	c, err := s.store.GetConversation(r.Context(), r.PathValue("id"))
	if errors.Is(err, errNotFound) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "conversation not found"})
		return
	}
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	reqs, err := s.store.ListRequests(r.Context(), c.ID, 200)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if r.URL.Query().Get("history") != "true" {
		c.History = nil
	}
	writeJSON(w, http.StatusOK, map[string]any{"conversation": c, "requests": reqs})
}

func (s *Server) listRequests(w http.ResponseWriter, r *http.Request) {
	list, err := s.store.ListRequests(r.Context(), r.URL.Query().Get("conversation_id"), queryLimit(r, 50))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"requests": list})
}

func (s *Server) listToolCalls(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad request id"})
		return
	}
	list, err := s.store.ListToolCalls(r.Context(), id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"tool_calls": list})
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

func queryLimit(r *http.Request, def int) int {
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 1000 {
			return n
		}
	}
	return def
}

// joinPrompts concatenates the bridge's own system prompt with the one Open
// WebUI sent (a per-model or per-chat system prompt), skipping empty parts.
func joinPrompts(parts ...string) string {
	var kept []string
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			kept = append(kept, p)
		}
	}
	return strings.Join(kept, "\n\n")
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

func writeOpenAIError(w http.ResponseWriter, status int, msg, typ string) {
	writeJSON(w, status, map[string]any{"error": map[string]any{"message": msg, "type": typ, "code": status}})
}
