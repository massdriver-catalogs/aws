package main

import (
	"encoding/json"
	"testing"
)

func TestShortID(t *testing.T) {
	taken := map[string]bool{"maya": true, "maya2": true, "template": true}
	cases := map[string]string{
		"Maya":                 "maya3",
		"Jo-Jo":                "jojo",
		"Anne-Marie O'Connell": "annemarieoconn",
		"Template":             "player",
		"'''":                  "player",
	}
	for name, want := range cases {
		if got := shortID(name, taken); got != want {
			t.Errorf("shortID(%q) = %q, want %q", name, got, want)
		}
	}
}

func TestPlansCoverEveryBundleParam(t *testing.T) {
	plans, err := loadPlans()
	if err != nil {
		t.Fatal(err)
	}
	if len(plans) != 3 {
		t.Fatalf("got %d plans", len(plans))
	}
	for _, p := range plans {
		for _, k := range []string{"size", "spot", "home_backups", "log_retention_days"} {
			if _, ok := p.Box[k]; !ok {
				t.Errorf("plan %s: box has no %s", p.ID, k)
			}
		}
		for _, k := range []string{"region", "partition_key", "sort_key", "point_in_time_recovery", "deletion_protection", "table_class", "encryption"} {
			if _, ok := p.Gamedata[k]; !ok {
				t.Errorf("plan %s: gamedata has no %s", p.ID, k)
			}
		}
		if p.Monthly.Gamedata < 1 {
			t.Errorf("plan %s: Saves & scores has no price", p.ID)
		}
	}
}

func TestSecretsAreStablePerLab(t *testing.T) {
	secret := []byte("0123456789abcdef")
	if labPassword(secret, "labs-maya") != labPassword(secret, "labs-maya") {
		t.Fatal("lab password changed between calls")
	}
	if labPassword(secret, "labs-maya") == labPassword(secret, "labs-sam") {
		t.Fatal("two labs share a password")
	}
	if playToken(secret, "labs-maya") == playToken(secret, "labs-sam") {
		t.Fatal("two labs share a play token")
	}
}

func TestJSONMapReadsBothShapes(t *testing.T) {
	for _, raw := range []string{`{"lab_plan":"small"}`, `"{\"lab_plan\":\"small\"}"`} {
		if got := jsonMap(json.RawMessage(raw))["lab_plan"]; got != "small" {
			t.Errorf("jsonMap(%s) lab_plan = %v", raw, got)
		}
	}
}

func TestLabState(t *testing.T) {
	l := &Labs{project: "labs", jobs: map[string]string{}, errs: map[string]string{}}
	env := Environment{
		ID: "labs-maya", Name: "Maya's Lab",
		RawAttrs: json.RawMessage(`{"lab_plan":"medium","player_age":"7"}`),
		Instances: []Instance{
			{ID: "labs-maya-box", Status: "PROVISIONED", LatestDeployment: &Deployment{Status: "COMPLETED", Action: "PROVISION"}},
			{ID: "labs-maya-gamedata", Status: "INITIALIZED"},
		},
	}
	lab := l.view(env)
	if lab.State != "ready" || lab.Player != "Maya" || lab.Age != 7 || lab.Plan != "medium" || lab.Gamedata {
		t.Fatalf("unexpected %+v", lab)
	}
	env.Instances[0].LatestDeployment = &Deployment{Status: "RUNNING", Action: "DECOMMISSION"}
	if got := l.view(env).State; got != "removing" {
		t.Fatalf("state = %s, want removing", got)
	}
}
