package db

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/elbertrondon/mia-agent/internal/api"
	"github.com/elbertrondon/mia-agent/internal/config"
	_ "github.com/go-sql-driver/mysql"
	_ "github.com/lib/pq"
	_ "github.com/microsoft/go-mssqldb"
	_ "modernc.org/sqlite"
)

const maxRows = 1000

type Executor struct {
	db     *sql.DB
	driver string
}

type QueryResult struct {
	Rows            []map[string]any
	Columns         []string
	ExecutionTimeMs int64
}

func NewExecutor(cfg *config.DatabaseConfig) (*Executor, error) {
	drvName, dsn := buildConnection(cfg)

	db, err := sql.Open(drvName, dsn)
	if err != nil {
		return nil, fmt.Errorf("open: %w", err)
	}
	db.SetMaxOpenConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)

	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("ping: %w", err)
	}

	return &Executor{db: db, driver: cfg.Driver}, nil
}

func (e *Executor) Execute(sqlStr string) (*QueryResult, error) {
	start := time.Now()

	rows, err := e.db.Query(sqlStr)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	cols, err := rows.Columns()
	if err != nil {
		return nil, err
	}

	var results []map[string]any
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		row := make(map[string]any, len(cols))
		for i, col := range cols {
			v := vals[i]
			if b, ok := v.([]byte); ok {
				v = string(b)
			}
			row[col] = v
		}
		results = append(results, row)
		if len(results) >= maxRows {
			break
		}
	}

	return &QueryResult{
		Rows:            results,
		Columns:         cols,
		ExecutionTimeMs: time.Since(start).Milliseconds(),
	}, nil
}

func (e *Executor) DiscoverSchema() ([]api.SchemaTable, error) {
	switch e.driver {
	case "mysql":
		return e.discoverMySQL()
	case "pgsql", "postgres":
		return e.discoverPostgres()
	case "sqlsrv":
		return e.discoverSQLServer()
	default:
		return nil, fmt.Errorf("schema discovery not supported for driver %q", e.driver)
	}
}

func (e *Executor) discoverMySQL() ([]api.SchemaTable, error) {
	rows, err := e.db.Query(`
		SELECT
			c.TABLE_NAME,
			c.COLUMN_NAME,
			c.DATA_TYPE,
			c.IS_NULLABLE,
			c.ORDINAL_POSITION,
			IF(pk.COLUMN_NAME IS NOT NULL, TRUE, FALSE) AS is_primary,
			IF(fk.COLUMN_NAME IS NOT NULL, TRUE, FALSE) AS is_foreign
		FROM INFORMATION_SCHEMA.COLUMNS c
		LEFT JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE pk
			ON  pk.TABLE_SCHEMA   = c.TABLE_SCHEMA
			AND pk.TABLE_NAME     = c.TABLE_NAME
			AND pk.COLUMN_NAME    = c.COLUMN_NAME
			AND pk.CONSTRAINT_NAME = 'PRIMARY'
		LEFT JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE fk
			ON  fk.TABLE_SCHEMA        = c.TABLE_SCHEMA
			AND fk.TABLE_NAME          = c.TABLE_NAME
			AND fk.COLUMN_NAME         = c.COLUMN_NAME
			AND fk.REFERENCED_TABLE_NAME IS NOT NULL
		WHERE c.TABLE_SCHEMA = DATABASE()
		ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanSchema(rows)
}

func (e *Executor) discoverPostgres() ([]api.SchemaTable, error) {
	rows, err := e.db.Query(`
		SELECT
			c.table_name,
			c.column_name,
			c.data_type,
			c.is_nullable,
			c.ordinal_position,
			COALESCE(pk.is_primary, FALSE),
			COALESCE(fk.is_foreign, FALSE)
		FROM information_schema.columns c
		LEFT JOIN (
			SELECT kcu.table_name, kcu.column_name, TRUE AS is_primary
			FROM information_schema.table_constraints tc
			JOIN information_schema.key_column_usage kcu
				ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
			WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = 'public'
		) pk ON pk.table_name = c.table_name AND pk.column_name = c.column_name
		LEFT JOIN (
			SELECT kcu.table_name, kcu.column_name, TRUE AS is_foreign
			FROM information_schema.table_constraints tc
			JOIN information_schema.key_column_usage kcu
				ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
			WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = 'public'
		) fk ON fk.table_name = c.table_name AND fk.column_name = c.column_name
		WHERE c.table_schema = 'public'
		ORDER BY c.table_name, c.ordinal_position`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanSchema(rows)
}

func (e *Executor) discoverSQLServer() ([]api.SchemaTable, error) {
	rows, err := e.db.Query(`
		SELECT
			c.TABLE_NAME,
			c.COLUMN_NAME,
			c.DATA_TYPE,
			c.IS_NULLABLE,
			c.ORDINAL_POSITION,
			CAST(CASE WHEN pk.COLUMN_NAME IS NOT NULL THEN 1 ELSE 0 END AS BIT),
			CAST(CASE WHEN fk.COLUMN_NAME IS NOT NULL THEN 1 ELSE 0 END AS BIT)
		FROM INFORMATION_SCHEMA.COLUMNS c
		LEFT JOIN (
			SELECT kcu.TABLE_NAME, kcu.COLUMN_NAME
			FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
			JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
			WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
		) pk ON pk.TABLE_NAME = c.TABLE_NAME AND pk.COLUMN_NAME = c.COLUMN_NAME
		LEFT JOIN (
			SELECT kcu.TABLE_NAME, kcu.COLUMN_NAME
			FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
			JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
			WHERE tc.CONSTRAINT_TYPE = 'FOREIGN KEY'
		) fk ON fk.TABLE_NAME = c.TABLE_NAME AND fk.COLUMN_NAME = c.COLUMN_NAME
		WHERE c.TABLE_SCHEMA = 'dbo'
		ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanSchema(rows)
}

func scanSchema(rows *sql.Rows) ([]api.SchemaTable, error) {
	tableMap := make(map[string]*api.SchemaTable)
	var order []string

	for rows.Next() {
		var (
			tableName  string
			colName    string
			dataType   string
			isNullable string
			position   int
			isPrimary  bool
			isForeign  bool
		)
		if err := rows.Scan(&tableName, &colName, &dataType, &isNullable, &position, &isPrimary, &isForeign); err != nil {
			return nil, err
		}

		if _, exists := tableMap[tableName]; !exists {
			tableMap[tableName] = &api.SchemaTable{Name: tableName}
			order = append(order, tableName)
		}
		tableMap[tableName].Columns = append(tableMap[tableName].Columns, api.SchemaColumn{
			Name:      colName,
			Type:      dataType,
			Nullable:  isNullable == "YES",
			IsPrimary: isPrimary,
			IsForeign: isForeign,
			Position:  position,
		})
	}

	tables := make([]api.SchemaTable, 0, len(order))
	for _, name := range order {
		tables = append(tables, *tableMap[name])
	}
	return tables, nil
}

func buildConnection(cfg *config.DatabaseConfig) (driverName, dsn string) {
	switch cfg.Driver {
	case "mysql":
		return "mysql", fmt.Sprintf("%s:%s@tcp(%s:%d)/%s?charset=utf8mb4&parseTime=true",
			cfg.Username, cfg.Password, cfg.Host, cfg.Port, cfg.Name)
	case "pgsql", "postgres":
		return "postgres", fmt.Sprintf("host=%s port=%d user=%s password=%s dbname=%s sslmode=disable",
			cfg.Host, cfg.Port, cfg.Username, cfg.Password, cfg.Name)
	case "sqlsrv":
		return "sqlserver", fmt.Sprintf("sqlserver://%s:%s@%s:%d?database=%s",
			cfg.Username, cfg.Password, cfg.Host, cfg.Port, cfg.Name)
	case "sqlite":
		return "sqlite", cfg.Host // host = file path for SQLite
	default:
		return cfg.Driver, ""
	}
}
