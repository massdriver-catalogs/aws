package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync"
	"time"
)

func sign(secret []byte, purpose, id string) []byte {
	m := hmac.New(sha256.New, secret)
	m.Write([]byte(purpose + ":" + id))
	return m.Sum(nil)
}

// labPassword is derived, not stored: the server sets it on the lab box when
// it creates the lab and can always work it out again.
func labPassword(secret []byte, id string) string {
	return base64.RawURLEncoding.EncodeToString(sign(secret, "lab-password", id))
}

// playToken goes in the game's address so the game's own files load without a
// cookie, which a sandboxed frame doesn't send.
func playToken(secret []byte, id string) string {
	return hex.EncodeToString(sign(secret, "play", id))[:32]
}

type target struct {
	agent   *url.URL
	game    *url.URL
	cluster string // the box's ECS cluster and service, to put it to sleep and wake it
	service string
	region  string
	fetched time.Time
}

// Boxes finds each lab's box and talks to its agent.
type Boxes struct {
	md       *Massdriver
	secret   []byte
	local    *target // a box on this machine, for trying the server without Massdriver
	localPW  string
	http     *http.Client
	mu       sync.Mutex
	targets  map[string]target
	sessions map[string]string
}

func (b *Boxes) target(ctx context.Context, lab string) (target, error) {
	if b.local != nil {
		return *b.local, nil
	}
	b.mu.Lock()
	t, ok := b.targets[lab]
	b.mu.Unlock()
	if ok && time.Since(t.fetched) < time.Minute {
		return t, nil
	}
	payload, err := b.md.Resource(ctx, lab+"-box", "lab")
	if err != nil {
		return target{}, err
	}
	agentURL, _ := payload["agent_url"].(string)
	gameURL, _ := payload["game_url"].(string)
	a, err1 := url.Parse(agentURL)
	g, err2 := url.Parse(gameURL)
	if agentURL == "" || gameURL == "" || err1 != nil || err2 != nil {
		return target{}, fmt.Errorf("lab %s publishes no usable addresses", lab)
	}
	t = target{agent: a, game: g, fetched: time.Now()}
	t.cluster, _ = payload["cluster_arn"].(string)
	t.service, _ = payload["service_name"].(string)
	t.region, _ = payload["region"].(string)
	b.mu.Lock()
	b.targets[lab] = t
	b.mu.Unlock()
	return t, nil
}

func (b *Boxes) call(ctx context.Context, lab, method, path string, body any, out any) error {
	t, err := b.target(ctx, lab)
	if err != nil {
		return err
	}
	var rdr io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rdr = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, t.agent.JoinPath(path).String(), rdr)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("content-type", "application/json")
	}
	password := labPassword(b.secret, lab)
	if b.local != nil {
		password = b.localPW
	}
	req.SetBasicAuth("opencode", password)
	resp, err := b.http.Do(req)
	if err != nil {
		return fmt.Errorf("the lab box isn't answering yet")
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if resp.StatusCode == http.StatusUnauthorized {
		return fmt.Errorf("the lab box didn't accept its password; deploy the lab again")
	}
	if resp.StatusCode >= 300 {
		return fmt.Errorf("the lab box said %d: %s", resp.StatusCode, truncate(string(raw), 200))
	}
	if out == nil || len(raw) == 0 {
		return nil
	}
	return json.Unmarshal(raw, out)
}

const sessionTitle = "Gamelab"

// session returns the lab's one chat, making it the first time.
func (b *Boxes) session(ctx context.Context, lab string) (string, error) {
	b.mu.Lock()
	id, ok := b.sessions[lab]
	b.mu.Unlock()
	if ok {
		return id, nil
	}
	var list []struct {
		ID    string `json:"id"`
		Title string `json:"title"`
		Time  struct {
			Created float64 `json:"created"`
		} `json:"time"`
	}
	if err := b.call(ctx, lab, http.MethodGet, "/session", nil, &list); err != nil {
		return "", err
	}
	var newest float64
	for _, s := range list {
		if s.Title == sessionTitle && s.Time.Created >= newest {
			id, newest = s.ID, s.Time.Created
		}
	}
	if id == "" {
		var created struct {
			ID string `json:"id"`
		}
		if err := b.call(ctx, lab, http.MethodPost, "/session", map[string]any{"title": sessionTitle}, &created); err != nil {
			return "", err
		}
		id = created.ID
	}
	b.mu.Lock()
	b.sessions[lab] = id
	b.mu.Unlock()
	return id, nil
}

func (b *Boxes) forget(lab string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.sessions, lab)
	delete(b.targets, lab)
}

// ChatMessage is what the player sees: the agent's words and a short line for
// each thing it did, never the code or command output.
type ChatMessage struct {
	ID      string   `json:"id"`
	Role    string   `json:"role"`
	Text    string   `json:"text"`
	Actions []string `json:"actions,omitempty"`
	Error   string   `json:"error,omitempty"`
}

type Chat struct {
	Busy     bool          `json:"busy"`
	Messages []ChatMessage `json:"messages"`
}

func (b *Boxes) Chat(ctx context.Context, lab string) (*Chat, error) {
	sid, err := b.session(ctx, lab)
	if err != nil {
		return nil, err
	}
	var raw []struct {
		Info struct {
			ID    string `json:"id"`
			Role  string `json:"role"`
			Error *struct {
				Name string `json:"name"`
				Data struct {
					Message string `json:"message"`
				} `json:"data"`
			} `json:"error"`
		} `json:"info"`
		Parts []struct {
			Type      string `json:"type"`
			Text      string `json:"text"`
			Synthetic bool   `json:"synthetic"`
			Tool      string `json:"tool"`
			State     struct {
				Status string         `json:"status"`
				Title  string         `json:"title"`
				Input  map[string]any `json:"input"`
			} `json:"state"`
		} `json:"parts"`
	}
	if err := b.call(ctx, lab, http.MethodGet, "/session/"+url.PathEscape(sid)+"/message", nil, &raw); err != nil {
		if strings.Contains(err.Error(), "404") {
			b.forget(lab)
		}
		return nil, err
	}
	chat := &Chat{Messages: []ChatMessage{}}
	for _, m := range raw {
		msg := ChatMessage{ID: m.Info.ID, Role: m.Info.Role}
		var texts []string
		for _, p := range m.Parts {
			switch p.Type {
			case "text":
				if !p.Synthetic && strings.TrimSpace(p.Text) != "" {
					texts = append(texts, p.Text)
				}
			case "tool":
				msg.Actions = append(msg.Actions, describeTool(p.Tool, p.State.Input, p.State.Status))
			}
		}
		msg.Text = strings.Join(texts, "\n\n")
		if m.Info.Error != nil && m.Info.Error.Name != "MessageAbortedError" {
			msg.Error = describeError(m.Info.Error.Name, m.Info.Error.Data.Message)
		}
		if msg.Text == "" && len(msg.Actions) == 0 && msg.Error == "" {
			continue
		}
		chat.Messages = append(chat.Messages, msg)
	}

	chat.Busy, _ = b.busy(ctx, lab, sid)
	return chat, nil
}

func (b *Boxes) busy(ctx context.Context, lab, sid string) (bool, error) {
	var status map[string]struct {
		Type string `json:"type"`
	}
	if err := b.call(ctx, lab, http.MethodGet, "/session/status", nil, &status); err != nil {
		return false, err
	}
	s, ok := status[sid]
	return ok && s.Type != "idle", nil
}

// Busy reports whether the helper is in the middle of a turn.
func (b *Boxes) Busy(ctx context.Context, lab string) (bool, error) {
	sid, err := b.session(ctx, lab)
	if err != nil {
		return false, err
	}
	return b.busy(ctx, lab, sid)
}

func describeTool(tool string, input map[string]any, status string) string {
	file, _ := input["filePath"].(string)
	if i := strings.LastIndex(file, "/"); i >= 0 {
		file = file[i+1:]
	}
	verb := map[string]string{
		"write": "Made", "edit": "Changed", "multiedit": "Changed", "patch": "Changed", "apply_patch": "Changed",
		"read": "Looked at", "glob": "Looked around", "grep": "Searched", "list": "Looked around",
		"bash": "Ran a command", "todowrite": "Made a plan", "todoread": "Checked the plan",
		"webfetch": "Read a web page", "websearch": "Searched the web", "task": "Asked a helper",
	}[tool]
	if verb == "" {
		verb = "Used " + tool
	}
	line := verb
	if file != "" {
		line += " " + file
	}
	if status == "error" {
		line += " (didn't work, trying again)"
	}
	return line
}

func describeError(name, message string) string {
	switch {
	case name == "ProviderAuthError" || strings.Contains(message, "x-api-key") || strings.Contains(message, "authentication"):
		return "The helper can't reach Claude: the lab's Anthropic API key is missing or wrong. A grown-up can fix it in Massdriver."
	case strings.Contains(strings.ToLower(message), "rate") || strings.Contains(message, "429"):
		return "The helper is a bit busy. Wait a minute and try again."
	case strings.Contains(strings.ToLower(message), "credit") || strings.Contains(strings.ToLower(message), "billing"):
		return "The lab's Anthropic account is out of credit. A grown-up can top it up."
	default:
		return "Something went wrong. Try saying that again."
	}
}

func (b *Boxes) Send(ctx context.Context, lab, text string) error {
	sid, err := b.session(ctx, lab)
	if err != nil {
		return err
	}
	return b.call(ctx, lab, http.MethodPost, "/session/"+url.PathEscape(sid)+"/prompt_async", map[string]any{
		"agent": "gamelab",
		"parts": []map[string]any{{"type": "text", "text": text}},
	}, nil)
}

func (b *Boxes) Stop(ctx context.Context, lab string) error {
	sid, err := b.session(ctx, lab)
	if err != nil {
		return err
	}
	return b.call(ctx, lab, http.MethodPost, "/session/"+url.PathEscape(sid)+"/abort", nil, nil)
}

// maxAPIBody caps what a game may send its box: a save or a score, never a file.
const maxAPIBody = 64 << 10

// Play proxies the lab's game server. Its files are read-only; only the
// saves and scores calls under api/ may write.
func (b *Boxes) Play(w http.ResponseWriter, r *http.Request, lab, rest string) {
	api := strings.HasPrefix(rest, "api/")
	switch {
	case r.Method == http.MethodGet || r.Method == http.MethodHead:
	case api && (r.Method == http.MethodPost || r.Method == http.MethodPut || r.Method == http.MethodOptions):
		r.Body = http.MaxBytesReader(w, r.Body, maxAPIBody)
	default:
		http.Error(w, "Games here are read-only.", http.StatusMethodNotAllowed)
		return
	}
	t, err := b.target(r.Context(), lab)
	if err != nil {
		http.Error(w, "This lab isn't ready yet.", http.StatusServiceUnavailable)
		return
	}
	proxy := &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.Out.URL.Scheme = t.game.Scheme
			pr.Out.URL.Host = t.game.Host
			pr.Out.URL.Path = strings.TrimSuffix(t.game.Path, "/") + "/" + rest
			pr.Out.URL.RawPath = ""
			pr.Out.URL.RawQuery = pr.In.URL.RawQuery
			pr.Out.Host = t.game.Host
			pr.Out.Header.Del("Cookie")
			pr.Out.Header.Del("Authorization")
		},
		ModifyResponse: func(resp *http.Response) error {
			resp.Header.Del("Set-Cookie")
			resp.Header.Set("Cache-Control", "no-store")
			// The game runs in a sandboxed frame on Gamelab's page and nowhere else.
			resp.Header.Set("Content-Security-Policy", "frame-ancestors 'self'")
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			http.Error(w, "The lab box isn't answering yet.", http.StatusBadGateway)
		},
	}
	proxy.ServeHTTP(w, r)
}
