package main

import (
	"context"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ecs"
)

// What a lab box is doing, as the pages show it.
const (
	powerAwake  = "awake"
	powerWaking = "waking"
	powerAsleep = "asleep"
)

type ecsAPI interface {
	DescribeServices(context.Context, *ecs.DescribeServicesInput, ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error)
	UpdateService(context.Context, *ecs.UpdateServiceInput, ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error)
}

type serviceState struct {
	desired, running int32
	checked          time.Time
}

// Power puts lab boxes nobody is using to sleep, by setting their ECS service
// to no tasks, and wakes them when someone opens the lab. A Massdriver deploy
// would take minutes; this takes one API call, and the box is back in about a
// minute with its home folder as it was.
type Power struct {
	boxes *Boxes
	idle  time.Duration
	ecs   func(region string) ecsAPI

	mu       sync.Mutex
	lastUsed map[string]time.Time
	services map[string]serviceState
}

func newPower(ctx context.Context, boxes *Boxes, idle time.Duration) (*Power, error) {
	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, err
	}
	return &Power{
		boxes: boxes,
		idle:  idle,
		ecs: func(region string) ecsAPI {
			return ecs.NewFromConfig(cfg, func(o *ecs.Options) { o.Region = region })
		},
		lastUsed: map[string]time.Time{},
		services: map[string]serviceState{},
	}, nil
}

// Touch records that someone used the lab just now.
func (p *Power) Touch(lab string) {
	if p == nil {
		return
	}
	p.mu.Lock()
	p.lastUsed[lab] = time.Now()
	p.mu.Unlock()
}

// Asleep answers from what the server saw in the last half minute, so it's
// cheap enough for every request.
func (p *Power) Asleep(ctx context.Context, lab string) bool {
	if p == nil {
		return false
	}
	s, _, managed, err := p.service(ctx, lab, 30*time.Second)
	return err == nil && managed && s.desired == 0
}

// Starting reports a box that was woken and has no task running yet.
func (p *Power) Starting(ctx context.Context, lab string) bool {
	if p == nil {
		return false
	}
	s, _, managed, err := p.service(ctx, lab, 5*time.Second)
	return err == nil && managed && s.desired > 0 && s.running == 0
}

// service reads the box's ECS service, or reports false for a box that
// doesn't say which service it is (one deployed before it could sleep).
func (p *Power) service(ctx context.Context, lab string, maxAge time.Duration) (serviceState, target, bool, error) {
	t, err := p.boxes.target(ctx, lab)
	if err != nil || t.service == "" || t.cluster == "" {
		return serviceState{}, t, false, err
	}
	p.mu.Lock()
	s, ok := p.services[lab]
	p.mu.Unlock()
	if ok && time.Since(s.checked) < maxAge {
		return s, t, true, nil
	}
	out, err := p.ecs(t.region).DescribeServices(ctx, &ecs.DescribeServicesInput{
		Cluster:  aws.String(t.cluster),
		Services: []string{t.service},
	})
	if err != nil {
		return serviceState{}, t, true, err
	}
	if len(out.Services) == 0 {
		return serviceState{}, t, false, nil
	}
	s = serviceState{desired: out.Services[0].DesiredCount, running: out.Services[0].RunningCount, checked: time.Now()}
	p.mu.Lock()
	p.services[lab] = s
	p.mu.Unlock()
	return s, t, true, nil
}

func (p *Power) scale(ctx context.Context, lab string, t target, count int32) error {
	_, err := p.ecs(t.region).UpdateService(ctx, &ecs.UpdateServiceInput{
		Cluster:      aws.String(t.cluster),
		Service:      aws.String(t.service),
		DesiredCount: aws.Int32(count),
	})
	if err != nil {
		return err
	}
	p.mu.Lock()
	s := p.services[lab]
	s.desired, s.checked = count, time.Now()
	p.services[lab] = s
	p.mu.Unlock()
	return nil
}

// Wake starts a sleeping box. It counts as using the lab, so the box isn't
// put back to sleep before anyone gets to it.
func (p *Power) Wake(ctx context.Context, lab string) error {
	if p == nil {
		return nil
	}
	p.Touch(lab)
	s, t, managed, err := p.service(ctx, lab, 0)
	if err != nil || !managed || s.desired > 0 {
		return err
	}
	slog.Info("waking lab", "lab", lab)
	return p.scale(ctx, lab, t, 1)
}

// State tells the lab page whether the box can take the player now. Awake
// means a task is running and its game server answers.
func (p *Power) State(ctx context.Context, lab string) string {
	if p == nil {
		return powerAwake
	}
	s, t, managed, err := p.service(ctx, lab, 3*time.Second)
	if err != nil {
		slog.Warn("checking lab box", "lab", lab, "err", err)
		return powerAwake
	}
	if !managed {
		return powerAwake
	}
	switch {
	case s.desired == 0:
		return powerAsleep
	case s.running == 0:
		return powerWaking
	}
	check, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(check, http.MethodGet, t.game.JoinPath("healthz").String(), nil)
	if err != nil {
		return powerWaking
	}
	resp, err := p.boxes.http.Do(req)
	if err != nil {
		return powerWaking
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return powerWaking
	}
	return powerAwake
}

// Sweep puts to sleep each awake box nobody has used for the idle time. A
// box the server hasn't seen used since it started counts from now, so a
// restart never sleeps a lab someone is in the middle of.
func (p *Power) Sweep(ctx context.Context, labs []string) {
	if p == nil {
		return
	}
	for _, lab := range labs {
		s, t, managed, err := p.service(ctx, lab, 0)
		if err != nil {
			slog.Warn("checking lab box", "lab", lab, "err", err)
			continue
		}
		if !managed || s.desired == 0 {
			continue
		}
		p.mu.Lock()
		last, seen := p.lastUsed[lab]
		if !seen {
			p.lastUsed[lab] = time.Now()
		}
		p.mu.Unlock()
		if !seen || time.Since(last) < p.idle {
			continue
		}
		// A turn can run for minutes with nobody typing; the helper is still working.
		if busy, err := p.boxes.Busy(ctx, lab); err == nil && busy {
			p.Touch(lab)
			continue
		}
		if err := p.scale(ctx, lab, t, 0); err != nil {
			slog.Warn("putting lab to sleep", "lab", lab, "err", err)
			continue
		}
		slog.Info("lab asleep", "lab", lab, "idle", time.Since(last).Round(time.Second).String())
	}
}
