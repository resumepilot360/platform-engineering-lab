// Package api implements the demo-backend HTTP API.
package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
)

// Config is resolved once at startup. Secret values are never stored here,
// only whether they are present, so they cannot leak through responses or logs.
type Config struct {
	Version      string
	Environment  string
	Greeting     string
	SecretsDir   string // directory of files projected from the demo-backend-db Secret
	dbConfigured bool
}

// LoadConfig reads configuration from the environment and checks that the
// database credential files exist and are non-empty.
func LoadConfig(version string) *Config {
	c := &Config{
		Version:     version,
		Environment: getenv("APP_ENVIRONMENT", "local"),
		Greeting:    getenv("GREETING", "hello"),
		SecretsDir:  getenv("SECRETS_DIR", "/etc/demo-backend/secrets"),
	}
	c.dbConfigured = nonEmptyFile(c.SecretsDir+"/db_username") && nonEmptyFile(c.SecretsDir+"/db_password")
	return c
}

// Server holds handlers and request counters.
type Server struct {
	cfg      *Config
	requests atomic.Uint64
	errors   atomic.Uint64
}

func New(cfg *Config) *Server { return &Server{cfg: cfg} }

// Routes returns the HTTP handler for the service.
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("GET /readyz", s.readyz)
	mux.HandleFunc("GET /api/greeting", s.greeting)
	mux.HandleFunc("GET /metrics", s.metrics)
	return s.count(mux)
}

// readyz fails until the database credentials have been delivered, so a pod
// without its Secret never receives traffic.
func (s *Server) readyz(w http.ResponseWriter, _ *http.Request) {
	if !s.cfg.dbConfigured {
		http.Error(w, "database credentials not configured", http.StatusServiceUnavailable)
		return
	}
	w.Write([]byte("ok"))
}

type greetingResponse struct {
	Message      string `json:"message"`
	Version      string `json:"version"`
	Environment  string `json:"environment"`
	DBConfigured bool   `json:"dbConfigured"`
}

func (s *Server) greeting(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimSpace(r.URL.Query().Get("name"))
	if name == "" {
		name = "world"
	}
	if len(name) > 64 {
		s.errors.Add(1)
		http.Error(w, "name too long", http.StatusBadRequest)
		return
	}
	writeJSON(w, greetingResponse{
		Message:      fmt.Sprintf("%s, %s", s.cfg.Greeting, name),
		Version:      s.cfg.Version,
		Environment:  s.cfg.Environment,
		DBConfigured: s.cfg.dbConfigured,
	})
}

// metrics exposes Prometheus text format without a client library dependency.
func (s *Server) metrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "# TYPE demo_backend_requests_total counter\ndemo_backend_requests_total %d\n", s.requests.Load())
	fmt.Fprintf(w, "# TYPE demo_backend_errors_total counter\ndemo_backend_errors_total %d\n", s.errors.Load())
	fmt.Fprintf(w, "# TYPE demo_backend_build_info gauge\ndemo_backend_build_info{version=%q} 1\n", s.cfg.Version)
}

func (s *Server) count(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.requests.Add(1)
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func nonEmptyFile(path string) bool {
	st, err := os.Stat(path)
	return err == nil && !st.IsDir() && st.Size() > 0
}
