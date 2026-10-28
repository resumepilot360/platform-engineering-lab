// Package web renders the demo-frontend page from the backend greeting API.
package web

import (
	"context"
	"encoding/json"
	"fmt"
	"html/template"
	"net/http"
	"time"
)

type Greeting struct {
	Message      string `json:"message"`
	Version      string `json:"version"`
	Environment  string `json:"environment"`
	DBConfigured bool   `json:"dbConfigured"`
}

type Server struct {
	backendURL string
	version    string
	client     *http.Client
}

func New(backendURL, version string) *Server {
	return &Server{backendURL: backendURL, version: version, client: &http.Client{Timeout: 3 * time.Second}}
}

var page = template.Must(template.New("page").Parse(`<!doctype html>
<html><head><meta charset="utf-8"><title>Platform Lab Demo</title></head>
<body>
<h1>{{.Greeting.Message}}!</h1>
<p>backend {{.Greeting.Version}} · frontend {{.FrontendVersion}} · env {{.Greeting.Environment}} · db configured: {{.Greeting.DBConfigured}}</p>
</body></html>`))

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	// Ready only if the backend answers: surfaces broken service-to-service paths
	// (e.g. a NetworkPolicy denial in Phase 6) as a failed readiness probe.
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		if _, err := s.fetch(r.Context(), "probe"); err != nil {
			http.Error(w, "backend unavailable", http.StatusServiceUnavailable)
			return
		}
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("GET /{$}", s.index)
	return mux
}

func (s *Server) index(w http.ResponseWriter, r *http.Request) {
	g, err := s.fetch(r.Context(), r.URL.Query().Get("name"))
	if err != nil {
		http.Error(w, "backend unavailable", http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = page.Execute(w, struct {
		Greeting        Greeting
		FrontendVersion string
	}{g, s.version})
}

func (s *Server) fetch(ctx context.Context, name string) (Greeting, error) {
	var g Greeting
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.backendURL+"/api/greeting", nil)
	if err != nil {
		return g, err
	}
	q := req.URL.Query()
	if name != "" {
		q.Set("name", name)
	}
	req.URL.RawQuery = q.Encode()
	resp, err := s.client.Do(req)
	if err != nil {
		return g, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return g, fmt.Errorf("backend returned %d", resp.StatusCode)
	}
	return g, json.NewDecoder(resp.Body).Decode(&g)
}
