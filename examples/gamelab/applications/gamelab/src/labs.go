package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed plans.json
var plansJSON []byte

type Plan struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Tagline  string   `json:"tagline"`
	Popular  bool     `json:"popular"`
	Features []string `json:"features"`
	Monthly  struct {
		Box      int `json:"box"`
		Gamedata int `json:"gamedata"`
	} `json:"monthly"`
	Box      map[string]any `json:"box"`
	Gamedata map[string]any `json:"gamedata"`
}

func loadPlans() ([]Plan, error) {
	var plans []Plan
	if err := json.Unmarshal(plansJSON, &plans); err != nil {
		return nil, err
	}
	return plans, nil
}

// Lab is one player's environment in the labs project, as the pages show it.
type Lab struct {
	ID        string // the environment's identifier, e.g. labs-maya
	Short     string // the part after the project, e.g. maya
	Player    string
	Age       int
	Plan      string
	Gamedata  bool // Saves & scores
	Lesson    string
	CreatedAt time.Time
	State     string // ready, building, removing, broken, stopped; the server adds asleep and waking
	Detail    string
}

func (l Lab) Ready() bool { return l.State == "ready" }

type NewLab struct {
	Player   string
	Age      int
	Plan     string
	Gamedata bool
	Lesson   string
	// Each lab brings its own Anthropic key, so its Claude bill and spend
	// limit belong to whoever made it. Never kept by the server; it goes
	// straight to the box as a secret.
	AnthropicKey string
}

// Labs forks, deploys and removes labs through Massdriver. Massdriver holds
// all the state, so a restarted server picks up where it was.
type Labs struct {
	md       *Massdriver
	project  string
	template string
	plans    []Plan
	secret   []byte
	model    string
	local    bool // no Massdriver: one lab, the box on this machine

	mu      sync.Mutex
	jobs    map[string]string             // lab ID -> what the setup is doing now
	errs    map[string]string             // lab ID -> why the setup stopped
	cancels map[string]context.CancelFunc // lab ID -> stops its setup
}

func (l *Labs) instance(lab, component string) string { return lab + "-" + component }

func (l *Labs) plan(id string) (Plan, bool) {
	for _, p := range l.plans {
		if p.ID == id {
			return p, true
		}
	}
	return Plan{}, false
}

func (l *Labs) setJob(id, step string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if step == "" {
		delete(l.jobs, id)
	} else {
		l.jobs[id] = step
		delete(l.errs, id)
	}
}

func (l *Labs) setErr(id, msg string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.jobs, id)
	l.errs[id] = msg
}

func (l *Labs) job(id string) (string, string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.jobs[id], l.errs[id]
}

var localLab = Lab{ID: "labs-local", Short: "local", Player: "Local Player", Age: 7, Plan: "small", State: "ready", Detail: "A box on this machine"}

var errLocal = errors.New("Gamelab isn't connected to Massdriver, so it can only open the lab on this machine.")

func (l *Labs) List(ctx context.Context) ([]Lab, error) {
	if l.local {
		return []Lab{localLab}, nil
	}
	envs, err := l.md.Environments(ctx, l.project)
	if err != nil {
		return nil, err
	}
	var labs []Lab
	for _, e := range envs {
		if e.ID == l.template {
			continue
		}
		labs = append(labs, l.view(e))
	}
	sort.Slice(labs, func(i, j int) bool { return labs[i].CreatedAt.After(labs[j].CreatedAt) })
	return labs, nil
}

func (l *Labs) Get(ctx context.Context, id string) (*Lab, error) {
	if l.local && id == localLab.ID {
		lab := localLab
		return &lab, nil
	}
	if l.local || !strings.HasPrefix(id, l.project+"-") || id == l.template {
		return nil, errNotFound
	}
	e, err := l.md.Environment(ctx, id)
	if err != nil {
		return nil, err
	}
	if e == nil {
		return nil, errNotFound
	}
	lab := l.view(*e)
	return &lab, nil
}

var errNotFound = errors.New("no such lab")

func (l *Labs) view(e Environment) Lab {
	age, _ := strconv.Atoi(e.Attr("player_age"))
	lab := Lab{
		ID:        e.ID,
		Short:     strings.TrimPrefix(e.ID, l.project+"-"),
		Player:    strings.TrimSuffix(e.Name, "'s Lab"),
		Age:       age,
		Plan:      e.Attr("lab_plan"),
		CreatedAt: e.CreatedAt,
	}
	box := e.Instance(l.instance(e.ID, "box"))
	gamedata := e.Instance(l.instance(e.ID, "gamedata"))
	lab.Gamedata = gamedata != nil && gamedata.Status == "PROVISIONED"

	if step, msg := l.job(e.ID); step != "" {
		lab.State, lab.Detail = "building", step
		return lab
	} else if msg != "" {
		lab.State, lab.Detail = "broken", msg
		return lab
	}

	for _, inst := range []*Instance{box, gamedata} {
		if inst == nil || inst.LatestDeployment == nil {
			continue
		}
		d := inst.LatestDeployment
		switch {
		case d.Action == "DECOMMISSION" && running(d.Status):
			lab.State, lab.Detail = "removing", "Putting the lab away"
			return lab
		case d.Action == "PROVISION" && running(d.Status):
			lab.State, lab.Detail = "building", "Building the lab"
			return lab
		case d.Action == "PROVISION" && (d.Status == "FAILED" || d.Status == "ABORTED"):
			lab.State, lab.Detail = "broken", "A deploy failed. Try again, or see "+inst.ID+" in Massdriver."
			return lab
		}
	}
	switch {
	case box != nil && box.Status == "PROVISIONED":
		lab.State, lab.Detail = "ready", "Ready to play"
	case box != nil && box.LatestDeployment != nil && box.LatestDeployment.Action == "DECOMMISSION":
		lab.State, lab.Detail = "removing", "Putting the lab away"
	default:
		lab.State, lab.Detail = "stopped", "Not set up yet"
	}
	return lab
}

func running(status string) bool {
	switch status {
	case "PENDING", "RUNNING", "APPROVED", "PROPOSED":
		return true
	}
	return false
}

var nameRe = regexp.MustCompile(`^[A-Za-z][A-Za-z '-]{0,29}$`)

// The lab-box bundle's lesson param allows the same characters, and the box
// quotes the lesson in the helper's prompt, so it never holds a quote mark or
// a line break.
var lessonRe = regexp.MustCompile(`^[A-Za-z0-9 .,'!?:;()&+=/%-]*$`)

const maxLesson = 200

// cleanLesson tidies what a parent typed: phone keyboards' curly apostrophes
// and dashes become plain ones, and runs of spaces one.
func cleanLesson(s string) (string, error) {
	s = strings.NewReplacer("\u2019", "'", "\u2018", "'", "\u2013", "-", "\u2014", "-").Replace(s)
	s = strings.Join(strings.Fields(s), " ")
	if len([]rune(s)) > maxLesson {
		return "", fmt.Errorf("Keep the lesson short: %d characters at most.", maxLesson)
	}
	if !lessonRe.MatchString(s) {
		return "", errors.New("Write the lesson with letters, numbers and simple punctuation, like \"counting to 20\".")
	}
	return s, nil
}

func (n NewLab) validate(l *Labs) error {
	n.Player = strings.TrimSpace(n.Player)
	if !nameRe.MatchString(n.Player) {
		return errors.New("Use a first name or nickname: letters, spaces, hyphens and apostrophes, up to 30.")
	}
	if n.Age < 5 || n.Age > 17 {
		return errors.New("Gamelab is for players from 5 to 17.")
	}
	if _, ok := l.plan(n.Plan); !ok {
		return errors.New("Pick a plan.")
	}
	if _, err := cleanLesson(n.Lesson); err != nil {
		return err
	}
	if !strings.HasPrefix(strings.TrimSpace(n.AnthropicKey), "sk-ant-") {
		return errors.New("Paste an Anthropic API key. It starts with sk-ant-.")
	}
	return nil
}

// shortID makes the environment identifier from the player's name: lowercase
// letters only, and a number when the name is taken. Massdriver allows 20.
func shortID(name string, taken map[string]bool) string {
	var b strings.Builder
	for _, r := range strings.ToLower(name) {
		if r >= 'a' && r <= 'z' {
			b.WriteRune(r)
		}
		if b.Len() == 14 {
			break
		}
	}
	base := b.String()
	if base == "" || base == "template" {
		base = "player"
	}
	if !taken[base] {
		return base
	}
	for n := 2; ; n++ {
		if c := base + strconv.Itoa(n); !taken[c] {
			return c
		}
	}
}

// Create forks the template and starts setting the lab up in the background.
// It returns once the environment exists, so the page can show it right away.
func (l *Labs) Create(ctx context.Context, in NewLab) (string, error) {
	if err := in.validate(l); err != nil {
		return "", err
	}
	if l.local {
		return "", errLocal
	}
	in.Player = strings.TrimSpace(in.Player)
	in.Lesson, _ = cleanLesson(in.Lesson)
	envs, err := l.md.Environments(ctx, l.project)
	if err != nil {
		return "", err
	}
	taken := map[string]bool{}
	for _, e := range envs {
		taken[strings.TrimPrefix(e.ID, l.project+"-")] = true
	}
	short := shortID(in.Player, taken)
	id := l.project + "-" + short
	plan, _ := l.plan(in.Plan)

	err = l.md.Fork(ctx, l.template, ForkInput{
		ID:          short,
		Name:        in.Player + "'s Lab",
		Description: fmt.Sprintf("%s, age %d, %s plan. Made in Gamelab.", in.Player, in.Age, plan.Name),
		Attributes:  map[string]any{"lab_plan": plan.ID, "player_age": strconv.Itoa(in.Age)},
	})
	if err != nil {
		return "", err
	}
	l.setJob(id, "Getting the lab ready")
	go l.setup(id, in, plan)
	return id, nil
}

// Resume runs the setup again for a lab whose setup stopped. Every step skips
// what's already done.
func (l *Labs) Resume(ctx context.Context, id string) error {
	if l.local {
		return errLocal
	}
	e, err := l.md.Environment(ctx, id)
	if err != nil {
		return err
	}
	if e == nil {
		return errNotFound
	}
	if step, _ := l.job(id); step != "" {
		return nil
	}
	age, _ := strconv.Atoi(e.Attr("player_age"))
	in := NewLab{Player: strings.TrimSuffix(e.Name, "'s Lab"), Age: age, Plan: e.Attr("lab_plan")}
	if in.Plan == "" {
		in.Plan = "small"
	}
	if in.Age == 0 {
		in.Age = 8
	}
	if s := e.Instance(l.instance(id, "gamedata")); s != nil && s.Status == "PROVISIONED" {
		in.Gamedata = true
	}
	// The box keeps the params of its last deploy, even one that failed.
	if in.Lesson, err = l.Lesson(ctx, id); err != nil {
		return err
	}
	plan, ok := l.plan(in.Plan)
	if !ok {
		return fmt.Errorf("unknown plan %q", in.Plan)
	}
	l.setJob(id, "Getting the lab ready")
	go l.setup(id, in, plan)
	return nil
}

// setup deploys the saves table if the parent picked it, then the box, which
// connects to it.
func (l *Labs) setup(id string, in NewLab, plan Plan) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Minute)
	l.mu.Lock()
	l.cancels[id] = cancel
	l.mu.Unlock()
	defer func() {
		cancel()
		l.mu.Lock()
		delete(l.cancels, id)
		l.mu.Unlock()
	}()
	log := slog.With("lab", id)

	fail := func(step string, err error) {
		if errors.Is(ctx.Err(), context.Canceled) {
			log.Info("lab setup stopped for removal")
			return
		}
		log.Error("lab setup stopped", "step", step, "err", err)
		l.setErr(id, step+" didn't work: "+friendly(err))
	}

	l.setJob(id, "Setting the lab's password")
	if err := l.md.SetSecret(ctx, l.instance(id, "box"), "LAB_PASSWORD", labPassword(l.secret, id)); err != nil {
		fail("Setting the lab's password", err)
		return
	}
	// A resumed lab already has its key; only a new one brings it.
	if key := strings.TrimSpace(in.AnthropicKey); key != "" {
		l.setJob(id, "Saving the lab's Anthropic key")
		if err := l.md.SetSecret(ctx, l.instance(id, "box"), "ANTHROPIC_API_KEY", key); err != nil {
			fail("Saving the lab's Anthropic key", err)
			return
		}
	}

	if in.Gamedata {
		const label = "Setting up saves and scores (about a minute)"
		l.setJob(id, label)
		if err := l.deployAndWait(ctx, l.instance(id, "gamedata"), plan.Gamedata); err != nil {
			fail(label, err)
			return
		}
	}

	box := map[string]any{
		"player_name":  in.Player,
		"player_age":   in.Age,
		"lesson":       in.Lesson,
		"model":        l.model,
		"image_tag":    "",
		"architecture": "arm64",
	}
	for k, v := range plan.Box {
		box[k] = v
	}
	l.setJob(id, "Building the lab box (about 5 minutes)")
	if err := l.deployAndWait(ctx, l.instance(id, "box"), box); err != nil {
		fail("Building the lab box", err)
		return
	}
	log.Info("lab ready")
	l.setJob(id, "")
}

// deployAndWait deploys an instance unless its last deploy already finished,
// so a resumed setup skips what's done.
func (l *Labs) deployAndWait(ctx context.Context, instance string, params map[string]any) error {
	e, err := l.md.Environment(ctx, instance[:strings.LastIndex(instance, "-")])
	if err != nil {
		return err
	}
	if e != nil {
		if inst := e.Instance(instance); inst != nil && inst.Status == "PROVISIONED" &&
			inst.LatestDeployment != nil && inst.LatestDeployment.Status == "COMPLETED" {
			return nil
		}
	}
	return l.deployNow(ctx, instance, params, "Gamelab")
}

func (l *Labs) deployNow(ctx context.Context, instance string, params map[string]any, message string) error {
	deployment, err := l.md.Deploy(ctx, instance, params, message)
	if err != nil {
		return err
	}
	tick := time.NewTicker(15 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			if errors.Is(ctx.Err(), context.Canceled) {
				return ctx.Err()
			}
			return fmt.Errorf("%s is still deploying after 90 minutes", instance)
		case <-tick.C:
		}
		d, err := l.md.Deployment(ctx, deployment)
		if err != nil {
			slog.Warn("checking deployment", "instance", instance, "err", err)
			continue
		}
		switch d.Status {
		case "COMPLETED":
			return nil
		case "FAILED", "ABORTED", "REJECTED":
			return fmt.Errorf("deployment of %s %s; its logs are in Massdriver", instance, strings.ToLower(d.Status))
		}
	}
}

// Lesson reads the lab's lesson from its box's params, where Massdriver keeps it.
func (l *Labs) Lesson(ctx context.Context, id string) (string, error) {
	if l.local {
		return "", nil
	}
	params, err := l.md.Params(ctx, l.instance(id, "box"))
	if err != nil {
		return "", err
	}
	lesson, _ := params["lesson"].(string)
	return lesson, nil
}

// SetLesson changes a ready lab's lesson and deploys its box in the
// background. The box restarts with it; a sleeping box stays asleep and has it
// when it wakes.
func (l *Labs) SetLesson(ctx context.Context, id, lesson string) error {
	if l.local {
		return errLocal
	}
	lesson, err := cleanLesson(lesson)
	if err != nil {
		return err
	}
	lab, err := l.Get(ctx, id)
	if err != nil {
		return err
	}
	if !lab.Ready() {
		return errors.New("The lab is busy. Change the lesson once it's ready.")
	}
	box := l.instance(id, "box")
	params, err := l.md.Params(ctx, box)
	if err != nil {
		return err
	}
	if current, _ := params["lesson"].(string); current == lesson {
		return nil
	}
	// Massdriver adds md_metadata itself on every deploy.
	delete(params, "md_metadata")
	params["lesson"] = lesson

	const label = "Giving the helper the new lesson (a few minutes)"
	message := "Gamelab: new lesson"
	if lesson == "" {
		message = "Gamelab: no lesson"
	}
	l.setJob(id, label)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Minute)
		l.mu.Lock()
		l.cancels[id] = cancel
		l.mu.Unlock()
		defer func() {
			cancel()
			l.mu.Lock()
			delete(l.cancels, id)
			l.mu.Unlock()
		}()
		if err := l.deployNow(ctx, box, params, message); err != nil {
			if errors.Is(ctx.Err(), context.Canceled) {
				return
			}
			slog.Error("changing the lesson", "lab", id, "err", err)
			l.setErr(id, "Changing the lesson didn't work: "+friendly(err))
			return
		}
		slog.Info("lesson changed", "lab", id, "lesson", lesson != "")
		l.setJob(id, "")
	}()
	return nil
}

// Remove decommissions a lab; the sweeper deletes the empty environment.
// A lab with nothing deployed is deleted right away.
func (l *Labs) Remove(ctx context.Context, id string) error {
	if l.local {
		return errLocal
	}
	e, err := l.md.Environment(ctx, id)
	if err != nil {
		return err
	}
	if e == nil || e.ID == l.template {
		return errNotFound
	}
	// A setup still running would deploy into the lab while it's coming down.
	l.mu.Lock()
	if cancel, ok := l.cancels[id]; ok {
		cancel()
	}
	delete(l.jobs, id)
	delete(l.errs, id)
	l.mu.Unlock()
	if e.Deletable.Result {
		return l.md.DeleteEnvironment(ctx, id)
	}
	return l.md.DecommissionEnvironment(ctx, id)
}

// Sweep deletes labs that finished decommissioning.
func (l *Labs) Sweep(ctx context.Context) {
	if l.local {
		return
	}
	envs, err := l.md.Environments(ctx, l.project)
	if err != nil {
		slog.Warn("sweep", "err", err)
		return
	}
	for _, e := range envs {
		if e.ID == l.template || !e.Deletable.Result {
			continue
		}
		box := e.Instance(l.instance(e.ID, "box"))
		if box == nil || box.LatestDeployment == nil || box.LatestDeployment.Action != "DECOMMISSION" ||
			box.LatestDeployment.Status != "COMPLETED" {
			continue
		}
		if err := l.md.DeleteEnvironment(ctx, e.ID); err != nil {
			slog.Warn("deleting removed lab", "lab", e.ID, "err", err)
		} else {
			slog.Info("deleted removed lab", "lab", e.ID)
		}
	}
}

func friendly(err error) string {
	return truncate(err.Error(), 240)
}
