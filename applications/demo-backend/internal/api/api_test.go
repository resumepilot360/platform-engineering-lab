package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newTestServer(t *testing.T, withSecrets bool) *Server {
	t.Helper()
	dir := t.TempDir()
	if withSecrets {
		for _, f := range []string{"db_username", "db_password"} {
			if err := os.WriteFile(filepath.Join(dir, f), []byte("x"), 0o600); err != nil {
				t.Fatal(err)
			}
		}
	}
	t.Setenv("SECRETS_DIR", dir)
	t.Setenv("APP_ENVIRONMENT", "test")
	t.Setenv("GREETING", "hi")
	return New(LoadConfig("v-test"))
}

func get(t *testing.T, s *Server, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	s.Routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestReadyzRequiresSecrets(t *testing.T) {
	if got := get(t, newTestServer(t, false), "/readyz").Code; got != http.StatusServiceUnavailable {
		t.Fatalf("readyz without secrets = %d, want 503", got)
	}
	if got := get(t, newTestServer(t, true), "/readyz").Code; got != http.StatusOK {
		t.Fatalf("readyz with secrets = %d, want 200", got)
	}
}

func TestGreeting(t *testing.T) {
	rec := get(t, newTestServer(t, true), "/api/greeting?name=dana")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	var body greetingResponse
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.Message != "hi, dana" || body.Environment != "test" || body.Version != "v-test" || !body.DBConfigured {
		t.Fatalf("unexpected body: %+v", body)
	}
}

func TestGreetingRejectsLongName(t *testing.T) {
	rec := get(t, newTestServer(t, true), "/api/greeting?name="+strings.Repeat("a", 65))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestResponsesNeverContainSecretValues(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "db_username"), []byte("u"), 0o600)
	os.WriteFile(filepath.Join(dir, "db_password"), []byte("s3cr3t-canary"), 0o600)
	t.Setenv("SECRETS_DIR", dir)
	s := New(LoadConfig("v"))
	for _, p := range []string{"/api/greeting", "/metrics", "/readyz", "/healthz"} {
		if strings.Contains(get(t, s, p).Body.String(), "s3cr3t-canary") {
			t.Fatalf("%s leaked the secret value", p)
		}
	}
}

func TestMetricsCountRequests(t *testing.T) {
	s := newTestServer(t, true)
	get(t, s, "/healthz")
	get(t, s, "/healthz")
	if !strings.Contains(get(t, s, "/metrics").Body.String(), "demo_backend_requests_total 3") {
		t.Fatal("request counter not incremented")
	}
}
