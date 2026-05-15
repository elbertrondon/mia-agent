package agent

import (
	"log"
	"time"

	"github.com/elbertrondon/mia-agent/internal/api"
	"github.com/elbertrondon/mia-agent/internal/config"
	"github.com/elbertrondon/mia-agent/internal/db"
)

type Agent struct {
	cfg      *config.Config
	client   *api.Client
	executor *db.Executor
	stopCh   chan struct{}
}

func New(cfg *config.Config) *Agent {
	return &Agent{
		cfg:    cfg,
		client: api.NewClient(cfg.MIAURL, cfg.AgentToken),
		stopCh: make(chan struct{}),
	}
}

func (a *Agent) Run() {
	log.Println("MIA Agent starting...")

	var err error
	a.executor, err = db.NewExecutor(&a.cfg.Database)
	if err != nil {
		log.Fatalf("cannot connect to database: %v", err)
	}
	log.Printf("connected to %s database at %s", a.cfg.Database.Driver, a.cfg.Database.Host)

	if err := a.pushSchema(); err != nil {
		log.Printf("warning: initial schema push failed: %v", err)
	}

	interval := time.Duration(a.cfg.PollIntervalSeconds) * time.Second
	if interval == 0 {
		interval = 3 * time.Second
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	log.Printf("polling every %s...", interval)

	for {
		select {
		case <-a.stopCh:
			log.Println("MIA Agent stopped.")
			return
		case <-ticker.C:
			a.pollAndExecute()
		}
	}
}

func (a *Agent) Stop() {
	close(a.stopCh)
}

func (a *Agent) pollAndExecute() {
	job, err := a.client.Poll()
	if err != nil {
		log.Printf("poll error: %v", err)
		return
	}
	if job == nil {
		return
	}

	log.Printf("executing job %s", job.ID)

	result, execErr := a.executor.Execute(job.SQL)

	var payload api.ResultPayload
	if execErr != nil {
		payload = api.ResultPayload{
			Success: false,
			Error:   execErr.Error(),
		}
	} else {
		payload = api.ResultPayload{
			Success:         true,
			Rows:            result.Rows,
			Columns:         result.Columns,
			ExecutionTimeMs: result.ExecutionTimeMs,
		}
	}

	if err := a.client.SubmitResult(job.ID, payload); err != nil {
		log.Printf("submitResult error (job %s): %v", job.ID, err)
	} else {
		log.Printf("job %s completed (%d rows)", job.ID, len(payload.Rows))
	}
}

func (a *Agent) pushSchema() error {
	log.Println("discovering schema...")

	tables, err := a.executor.DiscoverSchema()
	if err != nil {
		return err
	}

	if err := a.client.SubmitSchema(tables); err != nil {
		return err
	}

	log.Printf("schema pushed: %d tables", len(tables))
	return nil
}
