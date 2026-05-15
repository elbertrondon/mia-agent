package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

type Client struct {
	baseURL    string
	agentToken string
	http       *http.Client
}

type Job struct {
	ID     string `json:"id"`
	SQL    string `json:"sql"`
	Driver string `json:"driver"`
}

type PollResponse struct {
	Job *Job `json:"job"`
}

type ResultPayload struct {
	Success         bool             `json:"success"`
	Rows            []map[string]any `json:"rows,omitempty"`
	Columns         []string         `json:"columns,omitempty"`
	ExecutionTimeMs int64            `json:"execution_time_ms,omitempty"`
	Error           string           `json:"error,omitempty"`
}

type SchemaColumn struct {
	Name      string `json:"name"`
	Type      string `json:"type"`
	Nullable  bool   `json:"nullable"`
	IsPrimary bool   `json:"is_primary"`
	IsForeign bool   `json:"is_foreign"`
	Position  int    `json:"position"`
}

type SchemaTable struct {
	Name    string         `json:"name"`
	Columns []SchemaColumn `json:"columns"`
}

func NewClient(baseURL, agentToken string) *Client {
	return &Client{
		baseURL:    baseURL,
		agentToken: agentToken,
		http:       &http.Client{Timeout: 30 * time.Second},
	}
}

func (c *Client) Poll() (*Job, error) {
	req, err := c.newRequest("GET", "/api/agent/poll", nil)
	if err != nil {
		return nil, err
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("poll returned HTTP %d", resp.StatusCode)
	}

	var result PollResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	return result.Job, nil
}

func (c *Client) SubmitResult(jobID string, payload ResultPayload) error {
	req, err := c.newRequest("POST", "/api/agent/results/"+jobID, payload)
	if err != nil {
		return err
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("submitResult returned HTTP %d", resp.StatusCode)
	}
	return nil
}

func (c *Client) SubmitSchema(tables []SchemaTable) error {
	req, err := c.newRequest("POST", "/api/agent/schema", map[string]any{"tables": tables})
	if err != nil {
		return err
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("submitSchema returned HTTP %d", resp.StatusCode)
	}
	return nil
}

func (c *Client) newRequest(method, path string, body any) (*http.Request, error) {
	var bodyReader *bytes.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		bodyReader = bytes.NewReader(data)
	} else {
		bodyReader = bytes.NewReader(nil)
	}

	req, err := http.NewRequest(method, c.baseURL+path, bodyReader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.agentToken)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return req, nil
}
