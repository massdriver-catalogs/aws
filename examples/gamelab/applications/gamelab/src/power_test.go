package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ecs"
	"github.com/aws/aws-sdk-go-v2/service/ecs/types"
)

type fakeECS struct {
	desired, running int32
	updates          []int32
}

func (f *fakeECS) DescribeServices(context.Context, *ecs.DescribeServicesInput, ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error) {
	return &ecs.DescribeServicesOutput{Services: []types.Service{{DesiredCount: f.desired, RunningCount: f.running}}}, nil
}

func (f *fakeECS) UpdateService(_ context.Context, in *ecs.UpdateServiceInput, _ ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error) {
	f.desired = aws.ToInt32(in.DesiredCount)
	f.updates = append(f.updates, f.desired)
	return &ecs.UpdateServiceOutput{}, nil
}

func testPower(t *testing.T, busy bool) (*Power, *fakeECS) {
	status := `{}`
	if busy {
		status = `{"s1":{"type":"busy"}}`
	}
	box := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(status))
	}))
	t.Cleanup(box.Close)
	u, _ := url.Parse(box.URL)
	boxes := &Boxes{
		http:     box.Client(),
		secret:   []byte("0123456789abcdef"),
		targets:  map[string]target{"labs-maya": {agent: u, game: u.JoinPath("play/"), cluster: "c", service: "labs-maya-box", region: "us-east-1", fetched: time.Now()}},
		sessions: map[string]string{"labs-maya": "s1"},
	}
	f := &fakeECS{desired: 1, running: 1}
	return &Power{
		boxes: boxes, idle: time.Minute,
		ecs:      func(string) ecsAPI { return f },
		lastUsed: map[string]time.Time{}, services: map[string]serviceState{},
	}, f
}

func TestSleepsOnlyIdleLabs(t *testing.T) {
	ctx := context.Background()
	p, f := testPower(t, false)

	p.Sweep(ctx, []string{"labs-maya"})
	if len(f.updates) != 0 {
		t.Fatal("slept a lab the server had never seen used")
	}
	p.lastUsed["labs-maya"] = time.Now().Add(-2 * time.Minute)
	p.Sweep(ctx, []string{"labs-maya"})
	if len(f.updates) != 1 || f.desired != 0 || !p.Asleep(ctx, "labs-maya") {
		t.Fatalf("idle lab not asleep: %+v", f)
	}

	if err := p.Wake(ctx, "labs-maya"); err != nil {
		t.Fatal(err)
	}
	if f.desired != 1 {
		t.Fatal("didn't wake")
	}
	p.Sweep(ctx, []string{"labs-maya"})
	if f.desired != 1 {
		t.Fatal("slept a lab right after waking it")
	}
}

func TestNeverSleepsABusyHelper(t *testing.T) {
	ctx := context.Background()
	p, f := testPower(t, true)
	p.lastUsed["labs-maya"] = time.Now().Add(-2 * time.Minute)
	p.Sweep(ctx, []string{"labs-maya"})
	if len(f.updates) != 0 {
		t.Fatal("slept a lab whose helper was working")
	}
}
