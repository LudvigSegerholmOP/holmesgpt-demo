package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

// Store is the SQLite persistence layer.
//
// conversations: one row per Open WebUI chat, holding HolmesGPT's full
//
//	conversation_history (system prompt, tool calls, results).
//
// requests:      one row per chat completion request handled by the bridge.
// tool_calls:    every tool HolmesGPT ran while answering a request.
type Store struct {
	db *sql.DB
}

const schema = `
CREATE TABLE IF NOT EXISTS conversations (
  id           TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL DEFAULT '',
  user_name    TEXT NOT NULL DEFAULT '',
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL,
  turns        INTEGER NOT NULL DEFAULT 0,
  last_ask     TEXT NOT NULL DEFAULT '',
  history_json TEXT NOT NULL DEFAULT '[]'
);
CREATE TABLE IF NOT EXISTS requests (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation_id   TEXT NOT NULL,
  created_at        TEXT NOT NULL,
  completed_at      TEXT,
  duration_ms       INTEGER,
  status            TEXT NOT NULL,
  ask               TEXT NOT NULL,
  answer            TEXT,
  error             TEXT,
  model             TEXT NOT NULL DEFAULT '',
  prompt_tokens     INTEGER,
  completion_tokens INTEGER,
  total_tokens      INTEGER,
  cached_tokens     INTEGER,
  cost_usd          REAL,
  tool_call_count   INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS requests_conversation ON requests(conversation_id, id);
CREATE TABLE IF NOT EXISTS tool_calls (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  request_id      INTEGER NOT NULL REFERENCES requests(id) ON DELETE CASCADE,
  seq             INTEGER NOT NULL,
  tool_call_id    TEXT NOT NULL,
  tool_name       TEXT NOT NULL,
  toolset         TEXT NOT NULL DEFAULT '',
  description     TEXT NOT NULL DEFAULT '',
  params_json     TEXT,
  status          TEXT NOT NULL,
  error           TEXT,
  return_code     INTEGER,
  elapsed_seconds REAL,
  result          TEXT,
  started_at      TEXT NOT NULL,
  finished_at     TEXT
);
CREATE INDEX IF NOT EXISTS tool_calls_request ON tool_calls(request_id, seq);
`

func OpenStore(path string) (*Store, error) {
	if dir := filepath.Dir(path); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}
	dsn := "file:" + path + "?" + url.Values{
		"_pragma": []string{"journal_mode(WAL)", "busy_timeout(5000)", "foreign_keys(1)", "synchronous(NORMAL)"},
	}.Encode()
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// SQLite serialises writers anyway; one connection keeps things simple.
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) Ping(ctx context.Context) error { return s.db.PingContext(ctx) }

func now() string { return time.Now().UTC().Format(time.RFC3339Nano) }

// Conversation is the persisted HolmesGPT state for one chat.
type Conversation struct {
	ID        string            `json:"id"`
	UserID    string            `json:"user_id"`
	UserName  string            `json:"user_name"`
	CreatedAt string            `json:"created_at"`
	UpdatedAt string            `json:"updated_at"`
	Turns     int               `json:"turns"`
	LastAsk   string            `json:"last_ask"`
	History   []json.RawMessage `json:"history,omitempty"`
}

var errNotFound = errors.New("not found")

func (s *Store) GetConversation(ctx context.Context, id string) (*Conversation, error) {
	var c Conversation
	var hist string
	err := s.db.QueryRowContext(ctx,
		`SELECT id, user_id, user_name, created_at, updated_at, turns, last_ask, history_json FROM conversations WHERE id = ?`, id,
	).Scan(&c.ID, &c.UserID, &c.UserName, &c.CreatedAt, &c.UpdatedAt, &c.Turns, &c.LastAsk, &hist)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, errNotFound
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal([]byte(hist), &c.History); err != nil {
		return nil, fmt.Errorf("conversation %s: corrupt history: %w", id, err)
	}
	return &c, nil
}

// SaveConversation upserts the HolmesGPT history for a chat.
func (s *Store) SaveConversation(ctx context.Context, id, userID, userName, lastAsk string, history []json.RawMessage) error {
	hist, err := json.Marshal(history)
	if err != nil {
		return err
	}
	turns := 0
	for _, m := range history {
		if messageRole(m) == "user" {
			turns++
		}
	}
	ts := now()
	_, err = s.db.ExecContext(ctx, `
INSERT INTO conversations (id, user_id, user_name, created_at, updated_at, turns, last_ask, history_json)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  user_id = CASE WHEN excluded.user_id != '' THEN excluded.user_id ELSE conversations.user_id END,
  user_name = CASE WHEN excluded.user_name != '' THEN excluded.user_name ELSE conversations.user_name END,
  updated_at = excluded.updated_at,
  turns = excluded.turns,
  last_ask = excluded.last_ask,
  history_json = excluded.history_json`,
		id, userID, userName, ts, ts, turns, lastAsk, string(hist))
	return err
}

func (s *Store) ListConversations(ctx context.Context, limit int) ([]Conversation, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, user_id, user_name, created_at, updated_at, turns, last_ask FROM conversations ORDER BY updated_at DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Conversation{}
	for rows.Next() {
		var c Conversation
		if err := rows.Scan(&c.ID, &c.UserID, &c.UserName, &c.CreatedAt, &c.UpdatedAt, &c.Turns, &c.LastAsk); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// Request is one chat completion handled by the bridge.
type Request struct {
	ID               int64    `json:"id"`
	ConversationID   string   `json:"conversation_id"`
	CreatedAt        string   `json:"created_at"`
	CompletedAt      *string  `json:"completed_at"`
	DurationMs       *int64   `json:"duration_ms"`
	Status           string   `json:"status"`
	Ask              string   `json:"ask"`
	Answer           *string  `json:"answer"`
	Error            *string  `json:"error"`
	Model            string   `json:"model"`
	PromptTokens     *int     `json:"prompt_tokens"`
	CompletionTokens *int     `json:"completion_tokens"`
	TotalTokens      *int     `json:"total_tokens"`
	CachedTokens     *int     `json:"cached_tokens"`
	CostUSD          *float64 `json:"cost_usd"`
	ToolCallCount    int      `json:"tool_call_count"`
}

func (s *Store) CreateRequest(ctx context.Context, conversationID, ask, model string) (int64, error) {
	res, err := s.db.ExecContext(ctx,
		`INSERT INTO requests (conversation_id, created_at, status, ask, model) VALUES (?, ?, 'running', ?, ?)`,
		conversationID, now(), ask, model)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// RequestOutcome finalises a request row.
type RequestOutcome struct {
	Status           string // completed | failed | cancelled
	Answer           string
	Error            string
	PromptTokens     int
	CompletionTokens int
	TotalTokens      int
	CachedTokens     int
	CostUSD          float64
	ToolCallCount    int
	Started          time.Time
}

func (s *Store) FinishRequest(ctx context.Context, id int64, o RequestOutcome) error {
	var errPtr *string
	if o.Error != "" {
		errPtr = &o.Error
	}
	_, err := s.db.ExecContext(ctx, `
UPDATE requests SET completed_at = ?, duration_ms = ?, status = ?, answer = ?, error = ?,
  prompt_tokens = ?, completion_tokens = ?, total_tokens = ?, cached_tokens = ?, cost_usd = ?, tool_call_count = ?
WHERE id = ?`,
		now(), time.Since(o.Started).Milliseconds(), o.Status, o.Answer, errPtr,
		o.PromptTokens, o.CompletionTokens, o.TotalTokens, o.CachedTokens, o.CostUSD, o.ToolCallCount, id)
	return err
}

func (s *Store) ListRequests(ctx context.Context, conversationID string, limit int) ([]Request, error) {
	q := `SELECT id, conversation_id, created_at, completed_at, duration_ms, status, ask, answer, error, model,
	        prompt_tokens, completion_tokens, total_tokens, cached_tokens, cost_usd, tool_call_count FROM requests`
	args := []any{}
	if conversationID != "" {
		q += ` WHERE conversation_id = ?`
		args = append(args, conversationID)
	}
	q += ` ORDER BY id DESC LIMIT ?`
	args = append(args, limit)
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Request{}
	for rows.Next() {
		var r Request
		if err := rows.Scan(&r.ID, &r.ConversationID, &r.CreatedAt, &r.CompletedAt, &r.DurationMs, &r.Status, &r.Ask, &r.Answer, &r.Error, &r.Model,
			&r.PromptTokens, &r.CompletionTokens, &r.TotalTokens, &r.CachedTokens, &r.CostUSD, &r.ToolCallCount); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// ToolCall is one tool execution recorded during a request.
type ToolCall struct {
	ID             int64    `json:"id"`
	RequestID      int64    `json:"request_id"`
	Seq            int      `json:"seq"`
	ToolCallID     string   `json:"tool_call_id"`
	ToolName       string   `json:"tool_name"`
	Toolset        string   `json:"toolset"`
	Description    string   `json:"description"`
	Params         *string  `json:"params_json"`
	Status         string   `json:"status"`
	Error          *string  `json:"error"`
	ReturnCode     *int     `json:"return_code"`
	ElapsedSeconds *float64 `json:"elapsed_seconds"`
	Result         *string  `json:"result"`
	StartedAt      string   `json:"started_at"`
	FinishedAt     *string  `json:"finished_at"`
}

func (s *Store) StartToolCall(ctx context.Context, requestID int64, seq int, toolCallID, toolName string) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO tool_calls (request_id, seq, tool_call_id, tool_name, status, started_at) VALUES (?, ?, ?, ?, 'running', ?)`,
		requestID, seq, toolCallID, toolName, now())
	return err
}

// FinishToolCall records the result. If no matching running row exists (a
// result without a start event), a complete row is inserted instead.
func (s *Store) FinishToolCall(ctx context.Context, requestID int64, seq int, tr ToolResultData, result string) error {
	var params *string
	if len(tr.Result.Params) > 0 && string(tr.Result.Params) != "null" {
		p := string(tr.Result.Params)
		params = &p
	}
	name := tr.ToolName
	if name == "" {
		name = tr.Name
	}
	ts := now()
	res, err := s.db.ExecContext(ctx, `
UPDATE tool_calls SET tool_name = ?, toolset = ?, description = ?, params_json = ?, status = ?, error = ?, return_code = ?,
  elapsed_seconds = ?, result = ?, finished_at = ?
WHERE request_id = ? AND tool_call_id = ? AND status = 'running'`,
		name, tr.ToolsetName, tr.Description, params, tr.Result.Status, tr.Result.Error, tr.Result.ReturnCode,
		tr.Result.ElapsedSeconds, result, ts, requestID, tr.ToolCallID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n > 0 {
		return nil
	}
	_, err = s.db.ExecContext(ctx, `
INSERT INTO tool_calls (request_id, seq, tool_call_id, tool_name, toolset, description, params_json, status, error, return_code,
  elapsed_seconds, result, started_at, finished_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		requestID, seq, tr.ToolCallID, name, tr.ToolsetName, tr.Description, params, tr.Result.Status, tr.Result.Error, tr.Result.ReturnCode,
		tr.Result.ElapsedSeconds, result, ts, ts)
	return err
}

func (s *Store) ListToolCalls(ctx context.Context, requestID int64) ([]ToolCall, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT id, request_id, seq, tool_call_id, tool_name, toolset, description, params_json, status, error, return_code,
  elapsed_seconds, result, started_at, finished_at FROM tool_calls WHERE request_id = ? ORDER BY seq`, requestID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ToolCall{}
	for rows.Next() {
		var t ToolCall
		if err := rows.Scan(&t.ID, &t.RequestID, &t.Seq, &t.ToolCallID, &t.ToolName, &t.Toolset, &t.Description, &t.Params, &t.Status, &t.Error,
			&t.ReturnCode, &t.ElapsedSeconds, &t.Result, &t.StartedAt, &t.FinishedAt); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// Stats is a small summary for the / endpoint.
type Stats struct {
	Conversations int      `json:"conversations"`
	Requests      int      `json:"requests"`
	ToolCalls     int      `json:"tool_calls"`
	TotalTokens   int64    `json:"total_tokens"`
	TotalCostUSD  *float64 `json:"total_cost_usd"`
}

func (s *Store) Stats(ctx context.Context) (Stats, error) {
	var st Stats
	err := s.db.QueryRowContext(ctx, `
SELECT (SELECT COUNT(*) FROM conversations), (SELECT COUNT(*) FROM requests), (SELECT COUNT(*) FROM tool_calls),
  (SELECT COALESCE(SUM(total_tokens),0) FROM requests), (SELECT SUM(cost_usd) FROM requests)`).
		Scan(&st.Conversations, &st.Requests, &st.ToolCalls, &st.TotalTokens, &st.TotalCostUSD)
	return st, err
}

// messageRole extracts "role" from a raw OpenAI-format message.
func messageRole(m json.RawMessage) string {
	var r struct {
		Role string `json:"role"`
	}
	_ = json.Unmarshal(m, &r)
	return r.Role
}
