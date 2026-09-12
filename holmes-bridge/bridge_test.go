package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func raw(role, content string) json.RawMessage {
	b, _ := json.Marshal(map[string]string{"role": role, "content": content})
	return b
}

func msg(role, content string) oaiMessage {
	b, _ := json.Marshal(content)
	return oaiMessage{Role: role, Content: b}
}

func TestPlanTurnNew(t *testing.T) {
	p := planTurn([]oaiMessage{msg("user", "why is the frontend slow?")}, nil)
	if p.Source != "new" || p.Ask != "why is the frontend slow?" || p.UserTurn != 1 || len(p.History) != 0 {
		t.Fatalf("unexpected plan: %+v", p)
	}
}

func TestPlanTurnFollowUpUsesStoredHistory(t *testing.T) {
	stored := []json.RawMessage{raw("system", "sys"), raw("user", "q1"), raw("assistant", "a1")}
	msgs := []oaiMessage{msg("system", "be terse"), msg("user", "q1"), msg("assistant", "a1"), msg("user", "q2")}
	p := planTurn(msgs, stored)
	if p.Source != "stored" || p.Ask != "q2" || p.UserTurn != 2 || len(p.History) != 3 || p.SystemPrompt != "be terse" {
		t.Fatalf("unexpected plan: %+v", p)
	}
}

func TestPlanTurnRegenerateTruncates(t *testing.T) {
	stored := []json.RawMessage{raw("system", "sys"), raw("user", "q1"), raw("assistant", "a1"), raw("user", "q2"), raw("assistant", "a2")}
	// Regenerating turn 2: chat still has 2 user messages.
	msgs := []oaiMessage{msg("user", "q1"), msg("assistant", "a1"), msg("user", "q2 edited")}
	p := planTurn(msgs, stored)
	if p.Source != "stored" || p.Ask != "q2 edited" || len(p.History) != 3 {
		t.Fatalf("expected history truncated to 3, got %+v", p)
	}
	// Regenerating turn 1.
	p = planTurn([]oaiMessage{msg("user", "q1 again")}, stored)
	if p.Source != "stored" || len(p.History) != 1 || messageRole(p.History[0]) != "system" {
		t.Fatalf("expected only system prompt, got %+v", p)
	}
}

func TestPlanTurnRebuildsWhenStoredIsBehind(t *testing.T) {
	msgs := []oaiMessage{msg("user", "q1"), msg("assistant", "<details type=\"tool_calls\">\n<summary>x</summary>\n</details>\na1"), msg("user", "q2")}
	p := planTurn(msgs, nil)
	if p.Source != "rebuilt" || len(p.History) != 3 || messageRole(p.History[0]) != "system" {
		t.Fatalf("unexpected plan: %+v", p)
	}
	if !strings.Contains(string(p.History[2]), `"content":"a1"`) {
		t.Fatalf("details not stripped: %s", p.History[1])
	}
}

func TestPlanTurnContinue(t *testing.T) {
	stored := []json.RawMessage{raw("system", "sys"), raw("user", "q1"), raw("assistant", "a1")}
	p := planTurn([]oaiMessage{msg("user", "q1"), msg("assistant", "a1")}, stored)
	if p.Ask != "Continue." || p.Source != "stored" || len(p.History) != 3 {
		t.Fatalf("unexpected plan: %+v", p)
	}
}

func TestConversationKey(t *testing.T) {
	if conversationKey("abc", "u", nil) != "abc" {
		t.Fatal("chat id should win")
	}
	a := conversationKey("", "u1", []oaiMessage{msg("user", "hello")})
	b := conversationKey("local", "u1", []oaiMessage{msg("user", "hello"), msg("assistant", "x"), msg("user", "more")})
	if a != b || !strings.HasPrefix(a, "anon-") {
		t.Fatalf("fallback key not stable: %s vs %s", a, b)
	}
	if conversationKey("", "u2", []oaiMessage{msg("user", "hello")}) == a {
		t.Fatal("different users must not collide")
	}
}

func TestMessageTextParts(t *testing.T) {
	m := oaiMessage{Role: "user", Content: json.RawMessage(`[{"type":"text","text":"a"},{"type":"image_url","image_url":{"url":"x"}},{"type":"text","text":"b"}]`)}
	if got := m.text(); got != "a\nb" {
		t.Fatalf("got %q", got)
	}
}

func TestRenderToolResult(t *testing.T) {
	var tr ToolResultData
	err := json.Unmarshal([]byte(`{"tool_call_id":"call_1","tool_name":"bash","name":"bash","description":"kubectl get pods -n \"x\"",
	  "result":{"status":"success","data":"NAME  READY\nfoo   1/1","params":{"command":"kubectl get pods"},"error":null}}`), &tr)
	if err != nil {
		t.Fatal(err)
	}
	r := NewRenderer(1000)
	frag, full := r.ToolResult(tr)
	if full != "NAME  READY\nfoo   1/1" {
		t.Fatalf("full result: %q", full)
	}
	for _, want := range []string{
		`<details type="tool_calls" done="true" id="call_1" name="bash: kubectl get pods -n &#34;x&#34;"`,
		`arguments="{&#34;command&#34;:&#34;kubectl get pods&#34;}"`,
		`result="&#34;NAME  READY\nfoo   1/1&#34;"`,
		"<summary>bash: kubectl get pods -n &#34;x&#34;</summary>\n</details>\n",
	} {
		if !strings.Contains(frag, want) {
			t.Fatalf("fragment missing %q:\n%s", want, frag)
		}
	}
	if strings.Contains(frag, "status=") {
		t.Fatalf("success must not carry a status attribute: %s", frag)
	}
	// Attribute values must be single-line for Open WebUI's parser.
	open := frag[:strings.Index(frag, ">\n")]
	if strings.Contains(open, "\n") {
		t.Fatalf("newline inside details tag: %q", open)
	}
}

func TestRenderToolResultErrorAndTruncation(t *testing.T) {
	var tr ToolResultData
	_ = json.Unmarshal([]byte(`{"tool_call_id":"c","tool_name":"t","description":"d","result":{"status":"error","error":"boom","data":"0123456789"}}`), &tr)
	frag, full := NewRenderer(4).ToolResult(tr)
	if !strings.Contains(frag, `status="failed"`) || !strings.Contains(frag, "truncated") {
		t.Fatalf("bad fragment: %s", frag)
	}
	if full != "0123456789\nerror: boom" {
		t.Fatalf("full: %q", full)
	}
}

func TestToolLabel(t *testing.T) {
	var tr ToolResultData
	_ = json.Unmarshal([]byte(`{"tool_call_id":"c","tool_name":"execute_prometheus_range_query","toolset_name":"prometheus/metrics","description":"Prometheus: Query (Node CPU)"}`), &tr)
	if got := toolLabel(tr); got != "execute_prometheus_range_query (prometheus/metrics): Prometheus: Query (Node CPU)" {
		t.Fatalf("label: %q", got)
	}
	_ = json.Unmarshal([]byte(`{"tool_name":"get_file_contents","toolset_name":"github","description":"get_file_contents"}`), &tr)
	if got := toolLabel(tr); got != "get_file_contents (github)" {
		t.Fatalf("label: %q", got)
	}
	_ = json.Unmarshal([]byte(`{"tool_name":"bash","toolset_name":"bash","description":"kubectl get pods"}`), &tr)
	if got := toolLabel(tr); got != "bash: kubectl get pods" {
		t.Fatalf("label: %q", got)
	}
}

func TestResolveImages(t *testing.T) {
	r := NewRenderer(0)
	var withImg, noImg ToolResultData
	_ = json.Unmarshal([]byte(`{"tool_call_id":"img1","tool_name":"grafana_render_panel","result":{"status":"success","data":"ok","images":[{"mimeType":"image/png","data":"AAAA"}]}}`), &withImg)
	_ = json.Unmarshal([]byte(`{"tool_call_id":"q1","tool_name":"execute_prometheus_range_query","result":{"status":"success","data":"{}"}}`), &noImg)
	r.ToolResult(withImg)
	r.ToolResult(noImg)

	got := r.Answer("Spike here:\n\n![CPU spike](tool-image://q1)\n\nPanel:\n\n![Grafana panel](tool-image://img1)\n\n![](tool-image://missing) done")
	for _, want := range []string{"_CPU spike_", "![Grafana panel](data:image/png;base64,AAAA)"} {
		if !strings.Contains(got, want) {
			t.Fatalf("missing %q in:\n%s", want, got)
		}
	}
	if strings.Contains(got, "tool-image://") {
		t.Fatalf("unresolved reference in:\n%s", got)
	}
	if !strings.Contains(got, "\n\n done") {
		t.Fatalf("empty caption must vanish:\n%s", got)
	}
	// Narration between tool calls is rewritten as well.
	content := "see ![mem](tool-image://q1)"
	if out := r.Reasoning(AIMessageData{Content: &content}); !strings.Contains(out, "see _mem_") {
		t.Fatalf("reasoning content not rewritten: %q", out)
	}
}

func TestJoinPrompts(t *testing.T) {
	if got := joinPrompts("", " a ", "", "b"); got != "a\n\nb" {
		t.Fatalf("got %q", got)
	}
	if joinPrompts("", "  ") != "" {
		t.Fatal("expected empty")
	}
}

func TestRenderReasoning(t *testing.T) {
	reason, content := "Let me look\nat the pods.", "Checking pods now."
	out := NewRenderer(0).Reasoning(AIMessageData{Reasoning: &reason, Content: &content})
	if !strings.HasPrefix(out, `<details type="reasoning" done="true" duration="1">`+"\n<summary>Thought for 1 second</summary>\n> Let me look\n> at the pods.\n</details>\n") {
		t.Fatalf("bad reasoning block:\n%s", out)
	}
	if !strings.HasSuffix(out, "Checking pods now.\n\n") {
		t.Fatalf("content missing:\n%s", out)
	}
	if NewRenderer(0).Reasoning(AIMessageData{}) != "" {
		t.Fatal("empty message must render nothing")
	}
}

func TestReadSSE(t *testing.T) {
	body := "event: start_tool_calling\ndata: {\"tool_name\":\"bash\",\"id\":\"1\"}\n\n: ping\n\nevent: ai_answer_end\ndata: {\"analysis\":\"done\"}\n\n"
	var got []Event
	if err := readSSE(strings.NewReader(body), func(e Event) error { got = append(got, e); return nil }); err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Name != "start_tool_calling" || got[1].Name != "ai_answer_end" || string(got[1].Data) != `{"analysis":"done"}` {
		t.Fatalf("unexpected events: %+v", got)
	}
}

func TestStoreRoundTrip(t *testing.T) {
	st, err := OpenStore(t.TempDir() + "/t.db")
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	ctx := t.Context()

	if _, err := st.GetConversation(ctx, "c1"); err != errNotFound {
		t.Fatalf("expected not found, got %v", err)
	}
	reqID, err := st.CreateRequest(ctx, "c1", "why?", "holmesgpt")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.StartToolCall(ctx, reqID, 1, "call_1", "bash"); err != nil {
		t.Fatal(err)
	}
	var tr ToolResultData
	_ = json.Unmarshal([]byte(`{"tool_call_id":"call_1","tool_name":"bash","description":"kubectl get pods","toolset_name":"bash","result":{"status":"success","params":{"command":"kubectl get pods"},"elapsed_seconds":0.5,"return_code":0}}`), &tr)
	if err := st.FinishToolCall(ctx, reqID, 1, tr, "out"); err != nil {
		t.Fatal(err)
	}
	// Result without a start event is inserted whole.
	tr.ToolCallID = "call_2"
	if err := st.FinishToolCall(ctx, reqID, 2, tr, "out2"); err != nil {
		t.Fatal(err)
	}
	hist := []json.RawMessage{raw("system", "s"), raw("user", "why?"), raw("assistant", "because")}
	if err := st.SaveConversation(ctx, "c1", "u1", "Ludvig", "why?", hist); err != nil {
		t.Fatal(err)
	}
	if err := st.FinishRequest(ctx, reqID, RequestOutcome{Status: "completed", Answer: "because", TotalTokens: 10, ToolCallCount: 2}); err != nil {
		t.Fatal(err)
	}

	c, err := st.GetConversation(ctx, "c1")
	if err != nil || c.Turns != 1 || len(c.History) != 3 || c.UserName != "Ludvig" {
		t.Fatalf("conversation: %+v err=%v", c, err)
	}
	// Upsert without user info keeps the existing name.
	if err := st.SaveConversation(ctx, "c1", "", "", "again", hist); err != nil {
		t.Fatal(err)
	}
	c, _ = st.GetConversation(ctx, "c1")
	if c.UserName != "Ludvig" || c.LastAsk != "again" {
		t.Fatalf("upsert lost fields: %+v", c)
	}
	reqs, err := st.ListRequests(ctx, "c1", 10)
	if err != nil || len(reqs) != 1 || reqs[0].Status != "completed" || reqs[0].ToolCallCount != 2 || reqs[0].DurationMs == nil {
		t.Fatalf("requests: %+v err=%v", reqs, err)
	}
	tcs, err := st.ListToolCalls(ctx, reqID)
	if err != nil || len(tcs) != 2 || tcs[0].Status != "success" || *tcs[0].Result != "out" || tcs[0].Description != "kubectl get pods" {
		t.Fatalf("tool calls: %+v err=%v", tcs, err)
	}
	s, err := st.Stats(ctx)
	if err != nil || s.Conversations != 1 || s.Requests != 1 || s.ToolCalls != 2 {
		t.Fatalf("stats: %+v err=%v", s, err)
	}
}

func TestHolmesErrorMessage(t *testing.T) {
	cases := map[string]string{
		`{"detail":[{"type":"value_error","msg":"Value error, first item must be system"}]}`: "Value error, first item must be system",
		`{"detail":"model not found"}`: "model not found",
		`not json`:                     "not json",
	}
	for in, want := range cases {
		if got := holmesErrorMessage(in); got != want {
			t.Errorf("%s: got %q want %q", in, got, want)
		}
	}
}
