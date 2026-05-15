# MIA Agent — Contexto del proyecto

## Estado actual (15/05/2026 — actualizado)

### ¿Qué es esto?
Conector ligero escrito en Go que se instala en el ordenador Windows del cliente y permite que MIA Platform consulte bases de datos en redes privadas (detrás de firewalls) sin necesidad de abrir puertos de entrada.

El agente establece únicamente conexiones **salientes** (HTTPS) hacia MIA Platform. Nunca recibe conexiones entrantes.

---

### Stack técnico
- **Lenguaje:** Go 1.22
- **Dependencias:**
  - `github.com/kardianos/service` — Windows Service (también macOS/Linux)
  - `github.com/go-sql-driver/mysql` — MySQL
  - `github.com/lib/pq` — PostgreSQL
  - `github.com/microsoft/go-mssqldb` — SQL Server
  - `modernc.org/sqlite` — SQLite (pure Go, sin CGO)
- **Installer:** Inno Setup 6 (wizard con Pascal Script)
- **CI/CD:** GitHub Actions — compila para los 3 OS + empaqueta en cada tag `v*`

---

### Flujo de funcionamiento

```
Arranque
  └─▶ Conecta a la BD local
  └─▶ Descubre schema (tablas + columnas)
  └─▶ POST /api/agent/schema  →  MIA guarda el schema para la IA

Loop (cada 3 s)
  └─▶ GET /api/agent/poll
        ├─ job = null  →  no hacer nada
        └─ job.sql     →  ejecutar SQL localmente
                            └─▶ POST /api/agent/results/{job.id}
```

---

### Estructura de archivos

```
mia-agent/
├── main.go                     — Entry point + gestión del servicio (Windows/macOS/Linux)
├── go.mod
├── config.example.json         — Plantilla de configuración para el cliente
├── internal/
│   ├── config/config.go        — Lee config.json
│   ├── api/client.go           — Cliente HTTP: poll(), submitResult(), submitSchema()
│   ├── db/executor.go          — Ejecuta SQL + descubre schema (4 drivers)
│   └── agent/agent.go          — Loop principal de polling
├── installer/
│   ├── setup.iss               — Script Inno Setup (wizard de instalación Windows)
│   └── install.sh              — Script de instalación para macOS y Linux
└── .github/
    └── workflows/
        └── release.yml         — CI: 3 jobs → build (5 binarios) + installer Windows + GitHub Release
```

---

### Configuración (`config.json`)

```json
{
  "mia_url": "https://tu-instancia.miaplatform.com",
  "agent_token": "token-de-64-chars-generado-en-el-dashboard",
  "poll_interval_seconds": 3,
  "database": {
    "driver": "mysql",
    "host": "localhost",
    "port": 3306,
    "name": "nombre_bd",
    "username": "usuario",
    "password": "contraseña"
  }
}
```

**Drivers soportados:** `mysql` | `pgsql` | `sqlsrv` | `sqlite`

Para SQLite: `host` = ruta al archivo `.sqlite`, `port` = 0, `name`/`username`/`password` vacíos.

---

### API endpoints que consume

| Método | Endpoint | Descripción |
|--------|----------|-------------|
| `GET`  | `/api/agent/poll` | Recoge el siguiente job SQL pendiente |
| `POST` | `/api/agent/results/{job_id}` | Envía resultado (filas, columnas, tiempo, error) |
| `POST` | `/api/agent/schema` | Envía el schema de la BD local |

Todos autenticados con `Authorization: Bearer {agent_token}`.

---

### Payload de resultado

```json
{
  "success": true,
  "rows": [{ "col1": "val1", "col2": 42 }],
  "columns": ["col1", "col2"],
  "execution_time_ms": 12
}
```

En caso de error:
```json
{ "success": false, "error": "mensaje del error SQL" }
```

---

### Payload de schema

```json
{
  "tables": [
    {
      "name": "orders",
      "columns": [
        { "name": "id",         "type": "int",     "nullable": false, "is_primary": true,  "is_foreign": false, "position": 1 },
        { "name": "customer_id","type": "int",     "nullable": false, "is_primary": false, "is_foreign": true,  "position": 2 },
        { "name": "total",      "type": "decimal", "nullable": true,  "is_primary": false, "is_foreign": false, "position": 3 }
      ]
    }
  ]
}
```

---

### Límites

- Máximo **1000 filas** por query (hardcoded en `db/executor.go`)
- Timeout de conexión PDO: **5 min** de vida máxima por conexión
- Jobs pendientes expiran a los **5 minutos** si el agente no los recoge (gestionado en el backend Laravel)

---

### Instalación por plataforma

#### Windows — Wizard (`installer/setup.iss`)
El wizard guía al cliente en 4 pantallas:
1. **MIA Platform** — URL de la instancia + Agent Token
2. **Tipo de BD** — MySQL / PostgreSQL / SQL Server / SQLite
3. **Conexión** — Host, Puerto (auto-rellena según driver), Nombre de BD
4. **Credenciales** — Usuario + Contraseña *(se salta para SQLite)*

Resultado: escribe `config.json` en `C:\Program Files\MIA Agent\` y registra e inicia el Windows Service automáticamente. Al desinstalar: detiene y elimina el servicio.

#### macOS y Linux — Script (`installer/install.sh`)
```bash
# Opción A — One-liner (descarga desde GitHub Release)
curl -fsSL https://github.com/elbertrondon/mia-agent/releases/latest/download/install.sh | sudo bash

# Opción B — Manual (descarga binary + install.sh juntos)
sudo bash install.sh
```

El script detecta OS y arquitectura automáticamente, pide los datos de configuración de forma interactiva, escribe `/etc/mia-agent/config.json` (permisos 600) e instala el servicio del sistema (`launchd` en macOS, `systemd` en Linux).

---

### Binarios publicados en cada release

| Archivo | OS | Arch |
|---|---|---|
| `mia-agent-setup.exe` | Windows | amd64 (installer wizard) |
| `mia-agent.exe` | Windows | amd64 (binario standalone) |
| `mia-agent-macos-arm64` | macOS | Apple Silicon (M1/M2/M3) |
| `mia-agent-macos-amd64` | macOS | Intel |
| `mia-agent-linux-amd64` | Linux | x86-64 |
| `mia-agent-linux-arm64` | Linux | ARM64 (Raspberry Pi, Graviton) |
| `install.sh` | macOS / Linux | — |

---

### Cómo generar una release

```bash
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions (`release.yml`) ejecuta 3 jobs en paralelo (~5 min):
1. **`build`** (ubuntu) — cross-compila los 5 binarios + copia `install.sh`
2. **`windows-installer`** (windows) — descarga el `.exe`, compila el wizard con Inno Setup 6
3. **`release`** — descarga todos los artefactos y crea el GitHub Release con los 7 archivos adjuntos

---

### Comandos de uso manual (sin installer)

```bash
# Instalar como servicio Windows (requiere Administrador)
mia-agent.exe -config config.json -service install

# Gestión del servicio
mia-agent.exe -service start
mia-agent.exe -service stop
mia-agent.exe -service uninstall

# Ejecutar en primer plano (desarrollo / debug)
mia-agent.exe -config config.json
```

---

### Lo que está completado

- [x] Configuración JSON (`internal/config`)
- [x] Cliente HTTP MIA API (`internal/api`)
- [x] Ejecución SQL para MySQL, PostgreSQL, SQL Server, SQLite (`internal/db`)
- [x] Descubrimiento de schema para los 3 drivers principales
- [x] Loop de polling + envío de resultados (`internal/agent`)
- [x] Windows Service via `kardianos/service`
- [x] Installer Windows con wizard de configuración (Inno Setup 6)
- [x] Script de instalación macOS/Linux (`install.sh`) con detección automática de OS/arch
- [x] Pipeline CI/CD GitHub Actions — 3 jobs, 5 binarios + installer + install.sh en cada tag `v*`

---

### Pendiente

- [ ] System tray con icono de estado (conectado / sin conexión / error)
- [ ] Botón "Actualizar schema" desde el tray
- [ ] Auto-actualización del binario al publicar nueva versión
- [ ] Logs rotativos a archivo (actualmente solo stdout/Windows Event Log)
