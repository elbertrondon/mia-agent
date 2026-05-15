package main

import (
	"flag"
	"log"

	"github.com/elbertrondon/mia-agent/internal/agent"
	"github.com/elbertrondon/mia-agent/internal/config"
	"github.com/kardianos/service"
)

var svcLogger service.Logger

type program struct {
	a *agent.Agent
}

func (p *program) Start(_ service.Service) error {
	go p.a.Run()
	return nil
}

func (p *program) Stop(_ service.Service) error {
	p.a.Stop()
	return nil
}

func main() {
	configPath := flag.String("config", "config.json", "path to config.json")
	svcAction := flag.String("service", "", "service action: install | uninstall | start | stop")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("config error: %v", err)
	}

	svcConfig := &service.Config{
		Name:        "MIAAgent",
		DisplayName: "MIA Connector Agent",
		Description: "MIA Platform connector — executes AI-generated SQL on private network databases.",
		Arguments:   []string{"-config", *configPath},
	}

	prg := &program{a: agent.New(cfg)}
	svc, err := service.New(prg, svcConfig)
	if err != nil {
		log.Fatal(err)
	}

	svcLogger, _ = svc.Logger(nil)

	if *svcAction != "" {
		if err := service.Control(svc, *svcAction); err != nil {
			log.Fatalf("service control %q failed: %v", *svcAction, err)
		}
		log.Printf("service action %q completed", *svcAction)
		return
	}

	if err := svc.Run(); err != nil {
		log.Fatal(err)
	}
}
