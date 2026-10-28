// Command server runs the demo-backend API.
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

	"github.com/platform-lab/demo-backend/internal/api"
)

// version is set at build time: -ldflags "-X main.version=<git sha>".
var version = "dev"

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	addr := ":" + envOr("PORT", "8080")
	cfg := api.LoadConfig(version)
	srv := &http.Server{
		Addr:              addr,
		Handler:           api.New(cfg).Routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	go func() {
		log.Info("starting", "addr", addr, "version", version, "environment", cfg.Environment)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()
	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	log.Info("shutting down")
	_ = srv.Shutdown(shutdown)
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
