package web

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func fakeBackend(status int, body string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
		w.Write([]byte(body))
	}))
}

func get(s *Server, path string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	s.Routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestIndexRendersBackendGreeting(t *testing.T) {
	b := fakeBackend(200, `{"message":"hello, world","version":"b1","environment":"dev","dbConfigured":true}`)
	defer b.Close()
	rec := get(New(b.URL, "f1"), "/")
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "hello, world") || !strings.Contains(rec.Body.String(), "frontend f1") {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
}

func TestIndexEscapesBackendContent(t *testing.T) {
	b := fakeBackend(200, `{"message":"<script>alert(1)</script>"}`)
	defer b.Close()
	if strings.Contains(get(New(b.URL, "f"), "/").Body.String(), "<script>") {
		t.Fatal("backend content was not HTML-escaped")
	}
}

func TestBackendDownMeansNotReady(t *testing.T) {
	b := fakeBackend(503, "")
	defer b.Close()
	s := New(b.URL, "f")
	if get(s, "/readyz").Code != 503 || get(s, "/").Code != 502 {
		t.Fatal("expected 503 readyz and 502 index when backend fails")
	}
	if get(s, "/healthz").Code != 200 {
		t.Fatal("liveness must not depend on the backend")
	}
}
