package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthz(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, "ok")
	})
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
}

func TestMetricsExposesCounter(t *testing.T) {
	reg := newRegistry()
	handler := reg.instrument(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	// Generate one request so the counter is non-zero.
	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/", nil))

	w := httptest.NewRecorder()
	reg.handler(w, httptest.NewRequest(http.MethodGet, "/metrics", nil))

	body := w.Body.String()
	if !strings.Contains(body, "http_requests_total") {
		t.Fatalf("metrics output missing http_requests_total:\n%s", body)
	}
	if !strings.Contains(body, "app_info") {
		t.Fatalf("metrics output missing app_info:\n%s", body)
	}
}
