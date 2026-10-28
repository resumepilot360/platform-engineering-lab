//go:build integration

// Integration test: runs the real server binary path over TCP.
// go test -tags integration ./...
package main

import (
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/platform-lab/demo-backend/internal/api"
)

func TestServerOverTCP(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "db_username"), []byte("u"), 0o600)
	os.WriteFile(filepath.Join(dir, "db_password"), []byte("p"), 0o600)
	t.Setenv("SECRETS_DIR", dir)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: api.New(api.LoadConfig("it")).Routes(), ReadHeaderTimeout: time.Second}
	go srv.Serve(ln)
	defer srv.Close()

	base := "http://" + ln.Addr().String()
	for path, want := range map[string]string{"/readyz": "ok", "/api/greeting?name=it": `"message":"hello, it"`} {
		resp, err := http.Get(base + path)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != 200 || !strings.Contains(string(body), want) {
			t.Fatalf("%s: %d %s", path, resp.StatusCode, body)
		}
	}
}
