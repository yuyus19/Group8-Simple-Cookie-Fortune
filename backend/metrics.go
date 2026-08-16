package main

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics for the backend, exposed on /metrics for Prometheus to scrape.
var (
	httpRequests = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "fortune_http_requests_total",
			Help: "HTTP requests served, by handler, method and response code.",
		},
		[]string{"handler", "method", "code"},
	)

	httpDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "fortune_http_request_duration_seconds",
			Help:    "How long each handler took to answer, in seconds.",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"handler", "method"},
	)

	// A metric about the application rather than about HTTP. This is the one
	// worth putting on a dashboard: it answers "are we losing cookies again".
	fortunesStored = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "fortune_cookies_stored",
		Help: "Number of fortune cookies the backend currently knows about.",
	})

	redisUp = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "fortune_redis_up",
		Help: "1 when the backend is talking to Redis, 0 when it is running from memory.",
	})
)

// instrument wraps a handler so that everything it serves is counted and
// timed. Currying the handler label means each route reports separately
// without needing its own counter.
func instrument(name string, h http.Handler) http.Handler {
	return promhttp.InstrumentHandlerCounter(
		httpRequests.MustCurryWith(prometheus.Labels{"handler": name}),
		promhttp.InstrumentHandlerDuration(
			httpDuration.MustCurryWith(prometheus.Labels{"handler": name}),
			h,
		),
	)
}

// metricsHandler serves the Prometheus exposition format on /metrics.
func metricsHandler() http.Handler {
	return promhttp.Handler()
}
