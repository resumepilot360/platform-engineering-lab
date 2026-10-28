// Command server runs the demo-frontend.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/platform-lab/demo-frontend/internal/web"
)

var version = "dev"

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	addr := ":" + envOr("PORT", "8080")
	backend := envOr("BACKEND_URL", "http://demo-backend")
	srv := &http.Server{
		Addr:              addr,
		Handler:           web.New(backend, version).Routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	go func() {
		log.Info("starting", "addr", addr, "version", version, "backend", backend)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()
	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdown)
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
