// holmes-bridge exposes HolmesGPT as an OpenAI-compatible chat model so that
// Open WebUI (or any OpenAI client) can drive it.
//
// Every Open WebUI chat maps to one HolmesGPT conversation. HolmesGPT's full
// conversation history, including every tool call and result, is persisted in
// SQLite so follow-up questions reuse the investigation context instead of
// re-running it. Every request, answer and tool call is recorded as well.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Config is everything tunable through the environment.
type Config struct {
	ListenAddr         string
	HolmesURL          string
	HolmesTimeout      time.Duration
	DBPath             string
	ModelID            string
	ModelName          string
	APIKey             string
	ToolResultMaxChars int
	HiddenTools        []string
	SystemPrompt       string // appended to HolmesGPT's system prompt on every request
	LogLevel           slog.Level
}

// defaultSystemPrompt tells HolmesGPT about the client it is talking to.
// HolmesGPT's own prompt assumes its native UI, which renders tool-image://
// references and Prometheus results as charts; Open WebUI does neither.
const defaultSystemPrompt = `You are being used through Open WebUI. Every tool call you make is shown to the user as a collapsible step labelled with the tool name and toolset, in the order you ran them.

Rules for this client:
- Prefer the dedicated toolsets and MCP tools (Kubernetes, Prometheus/VictoriaMetrics, VictoriaLogs, Grafana, GitHub) over shell commands. If a shell/bash tool is unavailable, do not try to work around it; narrow your query with the dedicated tool instead.
- In your narration and in the final answer, name the tool or data source behind each finding, e.g. "VictoriaLogs query", "Prometheus range query", "kubernetes_tabular_query", "GitHub get_file_contents". The user wants to see exactly where each fact came from.
- This client does not draw charts from Prometheus query results. Do not embed Prometheus results as images. Summarise the numbers in text or a markdown table instead.
- Only write ![caption](tool-image://<id>) when a tool result explicitly gave you that exact line (Grafana render tools). Never invent it for other tools.`

func loadConfig() (Config, error) {
	c := Config{
		ListenAddr:         env("LISTEN_ADDR", ":8000"),
		HolmesURL:          strings.TrimRight(env("HOLMES_URL", "http://localhost:5050"), "/"),
		DBPath:             env("DB_PATH", "/data/holmes-bridge.db"),
		ModelID:            env("MODEL_ID", "holmesgpt"),
		ModelName:          env("MODEL_NAME", "HolmesGPT"),
		APIKey:             env("BRIDGE_API_KEY", ""),
		ToolResultMaxChars: 6000,
		// HolmesGPT's internal task list; noise in a chat, still recorded.
		HiddenTools:   strings.Split(env("HIDDEN_TOOLS", "TodoWrite"), ","),
		SystemPrompt:  defaultSystemPrompt,
		HolmesTimeout: 20 * time.Minute,
		LogLevel:      slog.LevelInfo,
	}
	// BRIDGE_SYSTEM_PROMPT replaces the default; set it to "none" to send nothing.
	if v, ok := os.LookupEnv("BRIDGE_SYSTEM_PROMPT"); ok {
		c.SystemPrompt = v
		if strings.EqualFold(strings.TrimSpace(v), "none") {
			c.SystemPrompt = ""
		}
	}
	if v := env("TOOL_RESULT_MAX_CHARS", ""); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 {
			return c, fmt.Errorf("TOOL_RESULT_MAX_CHARS: %q is not a non-negative integer", v)
		}
		c.ToolResultMaxChars = n
	}
	if v := env("HOLMES_TIMEOUT", ""); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return c, fmt.Errorf("HOLMES_TIMEOUT: %w", err)
		}
		c.HolmesTimeout = d
	}
	if v := strings.ToLower(env("LOG_LEVEL", "info")); v != "" {
		switch v {
		case "debug":
			c.LogLevel = slog.LevelDebug
		case "info":
			c.LogLevel = slog.LevelInfo
		case "warn", "warning":
			c.LogLevel = slog.LevelWarn
		case "error":
			c.LogLevel = slog.LevelError
		default:
			return c, fmt.Errorf("LOG_LEVEL: unknown level %q", v)
		}
	}
	return c, nil
}

func env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		fmt.Fprintln(os.Stderr, "config:", err)
		os.Exit(2)
	}
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel}))
	slog.SetDefault(logger)

	store, err := OpenStore(cfg.DBPath)
	if err != nil {
		logger.Error("open store", "path", cfg.DBPath, "err", err)
		os.Exit(1)
	}
	defer store.Close()

	holmes := NewHolmesClient(cfg.HolmesURL, cfg.HolmesTimeout)
	srv := NewServer(cfg, store, holmes, logger)

	httpServer := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           srv.Routes(),
		ReadHeaderTimeout: 10 * time.Second,
		// Investigations stream for minutes; no write timeout.
		WriteTimeout: 0,
		IdleTimeout:  120 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()

	logger.Info("holmes-bridge listening", "addr", cfg.ListenAddr, "holmes", cfg.HolmesURL, "db", cfg.DBPath, "model", cfg.ModelID)
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("serve", "err", err)
		os.Exit(1)
	}
}
