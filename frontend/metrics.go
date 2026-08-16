package main

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics for the frontend, exposed on /metrics for Prometheus to scrape.
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

	// Counts the times the backend could not be reached. This is the metric
	// that would have made the old log.Fatalln crash loop obvious at a glance.
	backendFailures = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "fortune_backend_failures_total",
			Help: "Requests the frontend could not complete because the backend did not answer.",
		},
		[]string{"action"},
	)
)

func instrument(name string, h http.Handler) http.Handler {
	return promhttp.InstrumentHandlerCounter(
		httpRequests.MustCurryWith(prometheus.Labels{"handler": name}),
		promhttp.InstrumentHandlerDuration(
			httpDuration.MustCurryWith(prometheus.Labels{"handler": name}),
			h,
		),
	)
}

func metricsHandler() http.Handler {
	return promhttp.Handler()
}
