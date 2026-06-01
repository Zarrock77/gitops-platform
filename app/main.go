// Command app is a tiny stateless web service used to demonstrate the GitOps
// platform end to end: it serves an HTML home page, liveness/readiness probes,
// and Prometheus metrics — all with the Go standard library (no dependencies),
// so the container build stays fully reproducible.
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"sort"
	"strconv"
	"sync"
	"time"
)

// version is injected at build time via -ldflags "-X main.version=...".
var version = "dev"

var startedAt = time.Now()

func main() {
	port := envOr("PORT", "8080")

	reg := newRegistry()
	mux := http.NewServeMux()

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
	})
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ready")
	})
	mux.HandleFunc("/metrics", reg.handler)
	mux.HandleFunc("/", home)

	handler := reg.instrument(mux)

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("starting app version=%s on :%s", version, port)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server error: %v", err)
	}
}

func home(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>GitOps Platform — demo app</title>
<style>
  body{font-family:system-ui,sans-serif;background:#0d1117;color:#e6edf3;
       display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}
  .card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:2.5rem 3rem;max-width:520px}
  h1{margin:0 0 .25rem;font-size:1.4rem}
  code{background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:.1rem .4rem}
  .meta{color:#7d8590;font-size:.85rem;margin-top:1.25rem;line-height:1.6}
  a{color:#58a6ff}
</style></head>
<body><div class="card">
  <h1>🚀 GitOps Platform — demo app</h1>
  <p>Déployée par <strong>ArgoCD</strong> depuis Git, packagée avec <strong>Helm</strong>,
     observée par <strong>Prometheus</strong> &amp; <strong>Grafana</strong>.</p>
  <p>Endpoints : <code>/healthz</code> · <code>/readyz</code> · <a href="/metrics">/metrics</a></p>
  <div class="meta">
    version : <code>%s</code><br>
    hostname : <code>%s</code><br>
    uptime : <code>%.0fs</code>
  </div>
</div></body></html>`, version, hostname(), time.Since(startedAt).Seconds())
}

// --- minimal Prometheus-style metrics registry (stdlib only) ---

type registry struct {
	mu       sync.Mutex
	requests map[string]int64 // key: method|code
}

func newRegistry() *registry {
	return &registry{requests: make(map[string]int64)}
}

// statusRecorder captures the response status code for metrics.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (reg *registry) instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		reg.mu.Lock()
		reg.requests[r.Method+"|"+strconv.Itoa(rec.status)]++
		reg.mu.Unlock()
	})
}

func (reg *registry) handler(w http.ResponseWriter, r *http.Request) {
	reg.mu.Lock()
	keys := make([]string, 0, len(reg.requests))
	for k := range reg.requests {
		keys = append(keys, k)
	}
	snapshot := make(map[string]int64, len(reg.requests))
	for k, v := range reg.requests {
		snapshot[k] = v
	}
	reg.mu.Unlock()
	sort.Strings(keys)

	w.Header().Set("Content-Type", "text/plain; version=0.0.4")

	fmt.Fprintln(w, "# HELP app_info Build information of the running app.")
	fmt.Fprintln(w, "# TYPE app_info gauge")
	fmt.Fprintf(w, "app_info{version=%q} 1\n", version)

	fmt.Fprintln(w, "# HELP app_uptime_seconds Seconds since the process started.")
	fmt.Fprintln(w, "# TYPE app_uptime_seconds gauge")
	fmt.Fprintf(w, "app_uptime_seconds %.3f\n", time.Since(startedAt).Seconds())

	fmt.Fprintln(w, "# HELP http_requests_total Total HTTP requests by method and status code.")
	fmt.Fprintln(w, "# TYPE http_requests_total counter")
	for _, k := range keys {
		method, code := splitKey(k)
		fmt.Fprintf(w, "http_requests_total{method=%q,code=%q} %d\n", method, code, snapshot[k])
	}
}

func splitKey(k string) (method, code string) {
	for i := 0; i < len(k); i++ {
		if k[i] == '|' {
			return k[:i], k[i+1:]
		}
	}
	return k, ""
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil {
		return "unknown"
	}
	return h
}
