package main

import (
	"context"
	"crypto/hmac"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"html/template"
	"io/fs"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

//go:embed web
var webFS embed.FS

type Server struct {
	password  string
	secret    []byte
	labs      *Labs
	boxes     *Boxes
	power     *Power
	plans     []Plan
	pages     map[string]*template.Template
	limiter   loginLimiter
	connected bool
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	if err := run(); err != nil {
		slog.Error("gamelab stopped", "err", err)
		os.Exit(1)
	}
}

func run() error {
	password := os.Getenv("GAMELAB_PASSWORD")
	secret := os.Getenv("SESSION_SECRET")
	if len(password) < 8 {
		return errors.New("set GAMELAB_PASSWORD to at least 8 characters")
	}
	if len(secret) < 16 {
		return errors.New("set SESSION_SECRET to at least 16 characters")
	}
	plans, err := loadPlans()
	if err != nil {
		return err
	}

	md := &Massdriver{
		URL:    env("MASSDRIVER_URL", "https://api.massdriver.cloud"),
		Org:    os.Getenv("MASSDRIVER_ORGANIZATION_ID"),
		APIKey: os.Getenv("MASSDRIVER_API_KEY"),
	}
	connected := md.Org != "" && md.APIKey != ""
	project := env("LABS_PROJECT", "labs")
	labs := &Labs{
		md:       md,
		project:  project,
		template: env("LAB_TEMPLATE", project+"-template"),
		plans:    plans,
		secret:   []byte(secret),
		model:    env("LAB_MODEL", "claude-opus-5-5"),
		local:    !connected,
		jobs:     map[string]string{},
		errs:     map[string]string{},
		cancels:  map[string]context.CancelFunc{},
	}
	boxes := &Boxes{
		md:       md,
		secret:   []byte(secret),
		http:     &http.Client{Timeout: 20 * time.Second},
		targets:  map[string]target{},
		sessions: map[string]string{},
	}
	if !connected {
		agentURL, _ := url.Parse(env("LOCAL_AGENT_URL", "http://localhost:4096"))
		gameURL, _ := url.Parse(env("LOCAL_GAME_URL", "http://localhost:8080/play/"))
		boxes.local = &target{agent: agentURL, game: gameURL}
		boxes.localPW = os.Getenv("LOCAL_LAB_PASSWORD")
		slog.Warn("MASSDRIVER_ORGANIZATION_ID or MASSDRIVER_API_KEY is not set; serving only the lab on this machine",
			"agent", agentURL.String(), "game", gameURL.String())
	}

	s := &Server{password: password, secret: []byte(secret), labs: labs, boxes: boxes, plans: plans, connected: connected}
	if err := s.parseTemplates(); err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if connected {
		idle, err := strconv.Atoi(env("LAB_IDLE_MINUTES", "30"))
		if err != nil || idle < 1 {
			return errors.New("set LAB_IDLE_MINUTES to a whole number of minutes, at least 1")
		}
		if s.power, err = newPower(ctx, boxes, time.Duration(idle)*time.Minute); err != nil {
			slog.Warn("no AWS configuration; labs won't sleep", "err", err)
		} else {
			slog.Info("labs sleep when unused", "minutes", idle)
		}
	}
	go func() {
		t := time.NewTicker(time.Minute)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				sweep, cancel := context.WithTimeout(ctx, 50*time.Second)
				labs.Sweep(sweep)
				if s.power != nil {
					if all, err := labs.List(sweep); err == nil {
						var ready []string
						for _, lab := range all {
							if lab.Ready() {
								ready = append(ready, lab.ID)
							}
						}
						s.power.Sweep(sweep, ready)
					}
				}
				cancel()
			}
		}
	}()

	srv := &http.Server{
		Addr:              ":" + env("PORT", "8080"),
		Handler:           s.routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()
	slog.Info("gamelab listening", "addr", srv.Addr, "connected", connected)
	if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	static, _ := fs.Sub(webFS, "web/static")
	mux.Handle("GET /static/", http.StripPrefix("/static/", http.FileServerFS(static)))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("ok\n")) })
	mux.HandleFunc("GET /login", s.loginPage)
	mux.HandleFunc("POST /login", s.login)
	mux.HandleFunc("POST /logout", s.logout)
	// The game's files carry their own token, since the sandboxed frame they
	// run in sends no cookie. Only saves and scores calls may write.
	mux.HandleFunc("GET /labs/{id}/play/{token}/{rest...}", s.play)
	for _, method := range []string{"POST", "PUT", "OPTIONS"} {
		mux.HandleFunc(method+" /labs/{id}/play/{token}/api/{rest...}", s.play)
	}

	mux.Handle("GET /{$}", s.auth(s.home))
	mux.Handle("GET /new", s.auth(s.newPage))
	mux.Handle("POST /new", s.auth(s.create))
	mux.Handle("GET /labs/{id}", s.auth(s.labPage))
	mux.Handle("POST /labs/{id}/remove", s.auth(s.remove))
	mux.Handle("POST /labs/{id}/resume", s.auth(s.resume))
	mux.Handle("POST /labs/{id}/lesson", s.auth(s.setLesson))
	mux.Handle("GET /labs/{id}/chat", s.auth(s.chat))
	mux.Handle("POST /labs/{id}/chat", s.auth(s.send))
	mux.Handle("POST /labs/{id}/stop", s.auth(s.stopAgent))
	return securityHeaders(mux)
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "same-origin")
		if !strings.Contains(r.URL.Path, "/play/") {
			h.Set("X-Frame-Options", "DENY")
			h.Set("Content-Security-Policy", "default-src 'self'; frame-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; frame-ancestors 'none'")
		}
		next.ServeHTTP(w, r)
	})
}

const cookieName = "gamelab"

func (s *Server) cookieValue(expires time.Time) string {
	exp := strconv.FormatInt(expires.Unix(), 10)
	return exp + "." + hex.EncodeToString(sign(s.secret, "session", exp))
}

func (s *Server) signedIn(r *http.Request) bool {
	c, err := r.Cookie(cookieName)
	if err != nil {
		return false
	}
	exp, mac, ok := strings.Cut(c.Value, ".")
	if !ok {
		return false
	}
	want := hex.EncodeToString(sign(s.secret, "session", exp))
	if !hmac.Equal([]byte(mac), []byte(want)) {
		return false
	}
	unix, err := strconv.ParseInt(exp, 10, 64)
	return err == nil && time.Now().Unix() < unix
}

// sameOrigin rejects form posts and API calls from other sites, which the
// browser would otherwise send with the cookie.
func sameOrigin(r *http.Request) bool {
	if r.Method == http.MethodGet || r.Method == http.MethodHead {
		return true
	}
	origin := r.Header.Get("Origin")
	if origin == "" {
		origin = r.Header.Get("Referer")
	}
	u, err := url.Parse(origin)
	return err == nil && u.Host == r.Host
}

func (s *Server) auth(h http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.signedIn(r) {
			if strings.HasSuffix(r.URL.Path, "/chat") || strings.HasSuffix(r.URL.Path, "/stop") {
				http.Error(w, "sign in again", http.StatusUnauthorized)
				return
			}
			http.Redirect(w, r, "/login", http.StatusSeeOther)
			return
		}
		if !sameOrigin(r) {
			http.Error(w, "That came from another site.", http.StatusForbidden)
			return
		}
		h(w, r)
	})
}

// loginLimiter slows down guessing: each wrong password waits longer, up to a
// minute, and a right one resets it.
type loginLimiter struct {
	mu       sync.Mutex
	failures int
	until    time.Time
}

func (l *loginLimiter) wait() time.Duration {
	l.mu.Lock()
	defer l.mu.Unlock()
	return time.Until(l.until)
}

func (l *loginLimiter) fail() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.failures++
	d := time.Duration(1<<min(l.failures, 6)) * time.Second
	l.until = time.Now().Add(min(d, time.Minute))
}

func (l *loginLimiter) reset() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.failures, l.until = 0, time.Time{}
}

func secure(r *http.Request) bool {
	return r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https"
}

func (s *Server) loginPage(w http.ResponseWriter, r *http.Request) {
	if s.signedIn(r) {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	s.render(w, "login", map[string]any{})
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	if !sameOrigin(r) {
		http.Error(w, "That came from another site.", http.StatusForbidden)
		return
	}
	if d := s.limiter.wait(); d > 0 {
		w.WriteHeader(http.StatusTooManyRequests)
		s.render(w, "login", map[string]any{"Error": "Too many tries. Wait " + strconv.Itoa(int(d.Seconds())+1) + " seconds."})
		return
	}
	given := r.PostFormValue("password")
	if subtle.ConstantTimeCompare([]byte(given), []byte(s.password)) != 1 {
		s.limiter.fail()
		w.WriteHeader(http.StatusUnauthorized)
		s.render(w, "login", map[string]any{"Error": "That's not the password."})
		return
	}
	s.limiter.reset()
	expires := time.Now().Add(12 * time.Hour)
	http.SetCookie(w, &http.Cookie{
		Name: cookieName, Value: s.cookieValue(expires), Path: "/", Expires: expires,
		HttpOnly: true, Secure: secure(r), SameSite: http.SameSiteStrictMode,
	})
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	if !sameOrigin(r) {
		http.Error(w, "That came from another site.", http.StatusForbidden)
		return
	}
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/", MaxAge: -1, HttpOnly: true, Secure: secure(r), SameSite: http.SameSiteStrictMode})
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

func (s *Server) home(w http.ResponseWriter, r *http.Request) {
	labs, err := s.labs.List(r.Context())
	for i := range labs {
		if labs[i].Ready() && s.power.Asleep(r.Context(), labs[i].ID) {
			labs[i].State, labs[i].Detail = "asleep", "Napping. Wakes up when you open it."
		}
	}
	data := map[string]any{"Labs": labs, "Connected": s.connected, "Plans": s.planNames()}
	if err != nil {
		slog.Error("listing labs", "err", err)
		data["Error"] = "Couldn't reach Massdriver: " + friendly(err)
	}
	s.render(w, "home", data)
}

func (s *Server) planNames() map[string]string {
	out := map[string]string{}
	for _, p := range s.plans {
		out[p.ID] = p.Name
	}
	return out
}

func (s *Server) newPage(w http.ResponseWriter, r *http.Request) {
	s.render(w, "new", map[string]any{"Plans": s.plans, "Form": map[string]string{"plan": "medium", "age": "7"}, "Ages": ages(), "Lessons": lessonIdeas})
}

type lessonIdea struct {
	Min, Max int
	Ideas    []string
}

var lessonIdeas = []lessonIdea{
	{5, 8, []string{"counting to 10", "counting to 20", "spelling three-letter words", "letter sounds", "shapes and colors", "adding small numbers"}},
	{9, 12, []string{"times tables", "adding fractions", "the planets", "telling time", "spelling tricky words", "countries and capitals"}},
	{13, 17, []string{"solving for x", "the periodic table", "Spanish words", "world history dates", "coordinates and graphs", "binary numbers"}},
}

func ages() []int {
	var out []int
	for a := 5; a <= 17; a++ {
		out = append(out, a)
	}
	return out
}

func (s *Server) create(w http.ResponseWriter, r *http.Request) {
	age, _ := strconv.Atoi(r.PostFormValue("age"))
	in := NewLab{
		Player:   r.PostFormValue("player"),
		Age:      age,
		Plan:     r.PostFormValue("plan"),
		Gamedata: r.PostFormValue("gamedata") == "on",
		Lesson:   r.PostFormValue("lesson"),

		AnthropicKey: r.PostFormValue("anthropic_key"),
	}
	id, err := s.labs.Create(r.Context(), in)
	if err != nil {
		form := map[string]string{"player": in.Player, "age": strconv.Itoa(in.Age), "plan": in.Plan, "lesson": in.Lesson}
		if in.Gamedata {
			form["gamedata"] = "on"
		}
		w.WriteHeader(http.StatusUnprocessableEntity)
		s.render(w, "new", map[string]any{"Plans": s.plans, "Form": form, "Ages": ages(), "Lessons": lessonIdeas, "Error": friendly(err)})
		return
	}
	http.Redirect(w, r, "/labs/"+url.PathEscape(id), http.StatusSeeOther)
}

func (s *Server) labPage(w http.ResponseWriter, r *http.Request) {
	lab, err := s.labs.Get(r.Context(), r.PathValue("id"))
	if errors.Is(err, errNotFound) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		http.Error(w, "Couldn't reach Massdriver: "+friendly(err), http.StatusBadGateway)
		return
	}
	if lab.Lesson, err = s.labs.Lesson(r.Context(), lab.ID); err != nil {
		slog.Warn("reading the lesson", "lab", lab.ID, "err", err)
	}
	// Opening the lab is using it: a sleeping box wakes, and the page checks
	// back until it answers.
	if lab.Ready() {
		s.power.Touch(lab.ID)
		switch s.power.State(r.Context(), lab.ID) {
		case powerAsleep:
			if err := s.power.Wake(r.Context(), lab.ID); err != nil {
				slog.Error("waking lab", "lab", lab.ID, "err", err)
			}
			fallthrough
		case powerWaking:
			lab.State, lab.Detail = "waking", "Waking up your lab… It was napping while nobody played. This takes about a minute."
		}
	}
	s.render(w, "lab", map[string]any{
		"Lab":     lab,
		"PlayURL": "/labs/" + url.PathEscape(lab.ID) + "/play/" + playToken(s.secret, lab.ID) + "/",
		"Plans":   s.planNames(),
	})
}

func (s *Server) remove(w http.ResponseWriter, r *http.Request) {
	if err := s.labs.Remove(r.Context(), r.PathValue("id")); err != nil {
		http.Error(w, "Couldn't remove the lab: "+friendly(err), http.StatusBadGateway)
		return
	}
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *Server) setLesson(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	lesson := r.PostFormValue("lesson")
	if r.PostFormValue("clear") != "" {
		lesson = ""
	}
	if err := s.labs.SetLesson(r.Context(), id, lesson); err != nil {
		if errors.Is(err, errNotFound) {
			http.NotFound(w, r)
			return
		}
		http.Error(w, "Couldn't change the lesson: "+friendly(err), http.StatusUnprocessableEntity)
		return
	}
	http.Redirect(w, r, "/labs/"+url.PathEscape(id), http.StatusSeeOther)
}

func (s *Server) resume(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := s.labs.Resume(r.Context(), id); err != nil {
		http.Error(w, "Couldn't continue setting up the lab: "+friendly(err), http.StatusBadGateway)
		return
	}
	http.Redirect(w, r, "/labs/"+url.PathEscape(id), http.StatusSeeOther)
}

// readyLab checks the lab exists and is ready, and its box awake, before the
// server talks to the box. With wake, a sleeping box is woken.
func (s *Server) readyLab(w http.ResponseWriter, r *http.Request, wake bool) (string, bool) {
	lab, err := s.labs.Get(r.Context(), r.PathValue("id"))
	if err != nil || lab == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "No such lab."})
		return "", false
	}
	if !lab.Ready() {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "The lab isn't ready yet.", "state": lab.State, "detail": lab.Detail})
		return "", false
	}
	if s.power.Asleep(r.Context(), lab.ID) {
		if wake {
			if err := s.power.Wake(r.Context(), lab.ID); err != nil {
				slog.Error("waking lab", "lab", lab.ID, "err", err)
			}
		}
		writeJSON(w, http.StatusConflict, map[string]any{"error": "Your lab is taking a nap.", "asleep": true})
		return "", false
	}
	return lab.ID, true
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("content-type", "application/json")
	w.Header().Set("cache-control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *Server) chat(w http.ResponseWriter, r *http.Request) {
	id, ok := s.readyLab(w, r, false)
	if !ok {
		return
	}
	chat, err := s.boxes.Chat(r.Context(), id)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": friendly(err)})
		return
	}
	writeJSON(w, http.StatusOK, chat)
}

const maxMessage = 2000

func (s *Server) send(w http.ResponseWriter, r *http.Request) {
	id, ok := s.readyLab(w, r, true)
	if !ok {
		return
	}
	s.power.Touch(id)
	var body struct {
		Text string `json:"text"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Couldn't read that."})
		return
	}
	text := strings.TrimSpace(body.Text)
	if text == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Say something first!"})
		return
	}
	if len([]rune(text)) > maxMessage {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "That's a lot! Try saying it in a shorter message."})
		return
	}
	if err := s.boxes.Send(r.Context(), id, text); err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": friendly(err)})
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]bool{"ok": true})
}

func (s *Server) stopAgent(w http.ResponseWriter, r *http.Request) {
	id, ok := s.readyLab(w, r, false)
	if !ok {
		return
	}
	if err := s.boxes.Stop(r.Context(), id); err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": friendly(err)})
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) play(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	want := playToken(s.secret, id)
	if subtle.ConstantTimeCompare([]byte(r.PathValue("token")), []byte(want)) != 1 {
		http.NotFound(w, r)
		return
	}
	rest := r.PathValue("rest")
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		rest = "api/" + rest
	}
	// Playing is using the lab. A game opened while its box sleeps wakes it
	// and checks back.
	s.power.Touch(id)
	asleep := s.power.Asleep(r.Context(), id)
	if asleep {
		if err := s.power.Wake(r.Context(), id); err != nil {
			slog.Error("waking lab", "lab", id, "err", err)
		}
	}
	if asleep || s.power.Starting(r.Context(), id) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Retry-After", "10")
		if strings.HasPrefix(rest, "api/") {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "The lab is waking up. Try again in a minute.", "waking": true})
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(wakingPage))
		return
	}
	s.boxes.Play(w, r, id, rest)
}

const wakingPage = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="5"><title>Waking up</title>
<body style="margin:0;height:100vh;display:grid;place-items:center;font:600 22px system-ui,sans-serif;background:#1b1340;color:#fff;text-align:center">
<p>Waking up your lab…<br><span style="font-weight:400;font-size:16px">The game will be back in about a minute.</span></p>`

func (s *Server) parseTemplates() error {
	funcs := template.FuncMap{}
	s.pages = map[string]*template.Template{}
	for _, page := range []string{"login", "home", "new", "lab"} {
		t, err := template.New("layout.html").Funcs(funcs).ParseFS(webFS, "web/templates/layout.html", "web/templates/"+page+".html")
		if err != nil {
			return err
		}
		s.pages[page] = t
	}
	return nil
}

func (s *Server) render(w http.ResponseWriter, page string, data map[string]any) {
	w.Header().Set("content-type", "text/html; charset=utf-8")
	w.Header().Set("cache-control", "no-store")
	data["Page"] = page
	if err := s.pages[page].Execute(w, data); err != nil {
		slog.Error("rendering", "page", page, "err", err)
	}
}
