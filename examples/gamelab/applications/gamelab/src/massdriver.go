package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Massdriver calls the V2 GraphQL API as the Gamelab service account.
type Massdriver struct {
	URL    string
	Org    string
	APIKey string
	HTTP   *http.Client
}

type gqlError struct {
	Message string `json:"message"`
}

type payloadMessages struct {
	Successful bool `json:"successful"`
	Messages   []struct {
		Field   string `json:"field"`
		Message string `json:"message"`
	} `json:"messages"`
}

func (p payloadMessages) err(op string) error {
	if p.Successful {
		return nil
	}
	var msgs []string
	for _, m := range p.Messages {
		if m.Field != "" {
			msgs = append(msgs, m.Field+": "+m.Message)
		} else {
			msgs = append(msgs, m.Message)
		}
	}
	if len(msgs) == 0 {
		msgs = []string{"not successful"}
	}
	return fmt.Errorf("%s: %s", op, strings.Join(msgs, "; "))
}

func (m *Massdriver) do(ctx context.Context, query string, vars map[string]any, out any) error {
	if vars == nil {
		vars = map[string]any{}
	}
	vars["org"] = m.Org
	body, err := json.Marshal(map[string]any{"query": query, "variables": vars})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(m.URL, "/")+"/api/v2", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("content-type", "application/json")
	// Service account tokens are bearer tokens; older organization keys use basic auth.
	if strings.HasPrefix(m.APIKey, "md_") {
		req.Header.Set("authorization", "Bearer "+m.APIKey)
	} else {
		req.Header.Set("authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(m.Org+":"+m.APIKey)))
	}
	client := m.HTTP
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode >= 300 {
		return fmt.Errorf("massdriver: HTTP %d: %s", resp.StatusCode, truncate(string(raw), 300))
	}
	var envelope struct {
		Data   json.RawMessage `json:"data"`
		Errors []gqlError      `json:"errors"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return err
	}
	if len(envelope.Errors) > 0 {
		msgs := make([]string, len(envelope.Errors))
		for i, e := range envelope.Errors {
			msgs[i] = e.Message
		}
		return errors.New("massdriver: " + strings.Join(msgs, "; "))
	}
	if out == nil {
		return nil
	}
	return json.Unmarshal(envelope.Data, out)
}

// jsonMap reads a Map scalar, which the API may return as an object or as a
// JSON-encoded string.
func jsonMap(raw json.RawMessage) map[string]any {
	out := map[string]any{}
	if len(raw) == 0 || string(raw) == "null" {
		return out
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		_ = json.Unmarshal([]byte(s), &out)
		return out
	}
	_ = json.Unmarshal(raw, &out)
	return out
}

func mapString(v map[string]any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

type Deployment struct {
	ID        string    `json:"id"`
	Status    string    `json:"status"`
	Action    string    `json:"action"`
	CreatedAt time.Time `json:"createdAt"`
}

type Instance struct {
	ID               string      `json:"id"`
	Status           string      `json:"status"`
	LatestDeployment *Deployment `json:"latestDeployment"`
}

type Environment struct {
	ID          string          `json:"id"`
	Name        string          `json:"name"`
	Description string          `json:"description"`
	RawAttrs    json.RawMessage `json:"attributes"`
	CreatedAt   time.Time       `json:"createdAt"`
	Instances   []Instance      `json:"instances"`
	Deletable   struct {
		Result bool `json:"result"`
	} `json:"deletable"`
}

func (e Environment) Attr(key string) string {
	v, _ := jsonMap(e.RawAttrs)[key].(string)
	return v
}

func (e Environment) Instance(id string) *Instance {
	for i := range e.Instances {
		if e.Instances[i].ID == id {
			return &e.Instances[i]
		}
	}
	return nil
}

const environmentFields = `
  id name description attributes createdAt
  instances { id status latestDeployment { id status action createdAt } }
  deletable { result }
`

func (m *Massdriver) Environments(ctx context.Context, project string) ([]Environment, error) {
	var all []Environment
	var next *string
	for {
		cursor := map[string]any{"limit": 100}
		if next != nil {
			cursor["next"] = *next
		}
		var out struct {
			Environments struct {
				Cursor struct {
					Next *string `json:"next"`
				} `json:"cursor"`
				Items []Environment `json:"items"`
			} `json:"environments"`
		}
		err := m.do(ctx, `query Labs($org: ID!, $project: ID!, $cursor: Cursor) {
  environments(organizationId: $org, filter: { projectId: { eq: $project } }, cursor: $cursor) {
    cursor { next }
    items {`+environmentFields+`}
  }
}`, map[string]any{"project": project, "cursor": cursor}, &out)
		if err != nil {
			return nil, err
		}
		all = append(all, out.Environments.Items...)
		next = out.Environments.Cursor.Next
		if next == nil || *next == "" {
			return all, nil
		}
	}
}

func (m *Massdriver) Environment(ctx context.Context, id string) (*Environment, error) {
	var out struct {
		Environment *Environment `json:"environment"`
	}
	err := m.do(ctx, `query Lab($org: ID!, $id: ID!) {
  environment(organizationId: $org, id: $id) {`+environmentFields+`}
}`, map[string]any{"id": id}, &out)
	return out.Environment, err
}

type ForkInput struct {
	ID          string
	Name        string
	Description string
	Attributes  map[string]any
}

func (m *Massdriver) Fork(ctx context.Context, parent string, in ForkInput) error {
	var out struct {
		Fork payloadMessages `json:"forkEnvironment"`
	}
	err := m.do(ctx, `mutation Fork($org: ID!, $parent: ID!, $input: ForkEnvironmentInput!) {
  forkEnvironment(organizationId: $org, parentId: $parent, input: $input) { successful messages { field message } }
}`, map[string]any{"parent": parent, "input": map[string]any{
		"id":                      in.ID,
		"name":                    in.Name,
		"description":             in.Description,
		"attributes":              mapString(in.Attributes),
		"copyEnvironmentDefaults": true,
		"copySecrets":             false,
		"copyRemoteReferences":    false,
	}}, &out)
	if err != nil {
		return err
	}
	return out.Fork.err("forkEnvironment")
}

func (m *Massdriver) SetSecret(ctx context.Context, instance, name, value string) error {
	var out struct {
		Set payloadMessages `json:"setInstanceSecret"`
	}
	err := m.do(ctx, `mutation Secret($org: ID!, $id: ID!, $input: SetInstanceSecretInput!) {
  setInstanceSecret(organizationId: $org, id: $id, input: $input) { successful messages { field message } }
}`, map[string]any{"id": instance, "input": map[string]any{"name": name, "value": value}}, &out)
	if err != nil {
		return err
	}
	return out.Set.err("setInstanceSecret " + name)
}

// Deploy provisions an instance with params and returns the deployment's ID.
func (m *Massdriver) Deploy(ctx context.Context, instance string, params map[string]any, message string) (string, error) {
	var out struct {
		Create struct {
			payloadMessages
			Result *struct {
				ID string `json:"id"`
			} `json:"result"`
		} `json:"createDeployment"`
	}
	err := m.do(ctx, `mutation Deploy($org: ID!, $id: ID!, $input: CreateDeploymentInput!) {
  createDeployment(organizationId: $org, id: $id, input: $input) { successful messages { field message } result { id } }
}`, map[string]any{"id": instance, "input": map[string]any{
		"action":  "PROVISION",
		"params":  mapString(params),
		"message": message,
	}}, &out)
	if err != nil {
		return "", err
	}
	if err := out.Create.err("createDeployment " + instance); err != nil {
		return "", err
	}
	if out.Create.Result == nil {
		return "", fmt.Errorf("createDeployment %s: no deployment returned", instance)
	}
	return out.Create.Result.ID, nil
}

func (m *Massdriver) Deployment(ctx context.Context, id string) (*Deployment, error) {
	var out struct {
		Deployment *Deployment `json:"deployment"`
	}
	err := m.do(ctx, `query Deployment($org: ID!, $id: UUID!) {
  deployment(organizationId: $org, id: $id) { id status action createdAt }
}`, map[string]any{"id": id}, &out)
	if err == nil && out.Deployment == nil {
		err = fmt.Errorf("deployment %s not found", id)
	}
	return out.Deployment, err
}

// Params reads the params an instance was last deployed with.
func (m *Massdriver) Params(ctx context.Context, instance string) (map[string]any, error) {
	var out struct {
		Instance *struct {
			Params json.RawMessage `json:"params"`
		} `json:"instance"`
	}
	err := m.do(ctx, `query Params($org: ID!, $id: ID!) {
  instance(organizationId: $org, id: $id) { params }
}`, map[string]any{"id": instance}, &out)
	if err != nil {
		return nil, err
	}
	if out.Instance == nil {
		return nil, fmt.Errorf("instance %s not found", instance)
	}
	return jsonMap(out.Instance.Params), nil
}

// Resource reads the payload of the resource an instance publishes on field.
func (m *Massdriver) Resource(ctx context.Context, instance, field string) (map[string]any, error) {
	var out struct {
		Instance *struct {
			Resources []struct {
				Field    string `json:"field"`
				Resource struct {
					Payload json.RawMessage `json:"payload"`
				} `json:"resource"`
			} `json:"resources"`
		} `json:"instance"`
	}
	err := m.do(ctx, `query Resource($org: ID!, $id: ID!) {
  instance(organizationId: $org, id: $id) { resources { field resource { payload } } }
}`, map[string]any{"id": instance}, &out)
	if err != nil {
		return nil, err
	}
	if out.Instance == nil {
		return nil, fmt.Errorf("instance %s not found", instance)
	}
	for _, r := range out.Instance.Resources {
		if r.Field == field {
			return jsonMap(r.Resource.Payload), nil
		}
	}
	return nil, errNotReady
}

func (m *Massdriver) environmentMutation(ctx context.Context, name, id string) error {
	var out map[string]payloadMessages
	err := m.do(ctx, fmt.Sprintf(`mutation M($org: ID!, $id: ID!) {
  %s(organizationId: $org, id: $id) { successful messages { field message } }
}`, name), map[string]any{"id": id}, &out)
	if err != nil {
		return err
	}
	return out[name].err(name)
}

func (m *Massdriver) DecommissionEnvironment(ctx context.Context, id string) error {
	return m.environmentMutation(ctx, "decommissionEnvironment", id)
}

func (m *Massdriver) DeleteEnvironment(ctx context.Context, id string) error {
	return m.environmentMutation(ctx, "deleteEnvironment", id)
}

var errNotReady = errors.New("not ready yet")

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
