package config

import (
	"encoding/json"
	"os"
)

type DatabaseConfig struct {
	Driver   string `json:"driver"`
	Host     string `json:"host"`
	Port     int    `json:"port"`
	Name     string `json:"name"`
	Username string `json:"username"`
	Password string `json:"password"`
}

type Config struct {
	MIAURL              string         `json:"mia_url"`
	AgentToken          string         `json:"agent_token"`
	Database            DatabaseConfig `json:"database"`
	PollIntervalSeconds int            `json:"poll_interval_seconds"`
}

func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	cfg := &Config{PollIntervalSeconds: 3}
	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, err
	}
	return cfg, nil
}
