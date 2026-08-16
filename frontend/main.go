package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"log"
	"math/rand"
	"net/http"
	"time"
)

var BACKEND_DNS = getEnv("BACKEND_DNS", "localhost")
var BACKEND_PORT = getEnv("BACKEND_PORT", "9000")

// Kept in a variable rather than built inside each handler so the tests can
// point the handlers at a stub backend.
var backendBaseURL = fmt.Sprintf("http://%s:%s", BACKEND_DNS, BACKEND_PORT)

type fortune struct {
	ID      string `json:"id" redis:"id"`
	Message string `json:"message" redis:"message"`
}

type newFortune struct {
	Message string `json:"message"`
}

// use a custom client, because we don't do blocking operations wihout timeouts
var myClient = &http.Client{Timeout: 10 * time.Second}

func HealthzHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	io.WriteString(w, "healthy")
}

// backendUnavailable is what every handler now does when it cannot reach the
// backend.
//
// It used to be log.Fatalln, which calls os.Exit(1). One failed request took
// the entire frontend process down with it, so pressing a button while the
// backend was restarting killed the server for everybody. Under Kubernetes
// that showed up as a CrashLoopBackOff instead of a message. A 502 says the
// same thing without the suicide.
func backendUnavailable(w http.ResponseWriter, action string, err error) {
	backendFailures.WithLabelValues(action).Inc()
	log.Printf("backend request failed while %s: %v", action, err)
	http.Error(w,
		"The fortune backend is unavailable right now. Please try again in a moment.",
		http.StatusBadGateway)
}

// RandomHandler returns a single random fortune as plain text.
func RandomHandler(w http.ResponseWriter, r *http.Request) {
	resp, err := myClient.Get(fmt.Sprintf("%s/fortunes/random", backendBaseURL))
	if err != nil {
		backendUnavailable(w, "fetching a random fortune", err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		backendUnavailable(w, "fetching a random fortune",
			fmt.Errorf("backend answered %d", resp.StatusCode))
		return
	}

	f := new(fortune)
	if err := json.NewDecoder(resp.Body).Decode(f); err != nil {
		backendUnavailable(w, "decoding a random fortune", err)
		return
	}

	fmt.Fprint(w, f.Message)
}

// AllHandler renders every fortune through templates/fortunes.html.
func AllHandler(w http.ResponseWriter, r *http.Request) {
	resp, err := myClient.Get(fmt.Sprintf("%s/fortunes", backendBaseURL))
	if err != nil {
		backendUnavailable(w, "listing fortunes", err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		backendUnavailable(w, "listing fortunes",
			fmt.Errorf("backend answered %d", resp.StatusCode))
		return
	}

	fortunes := new([]fortune)
	if err := json.NewDecoder(resp.Body).Decode(fortunes); err != nil {
		backendUnavailable(w, "decoding the fortune list", err)
		return
	}

	tmpl, err := template.ParseFiles("./templates/fortunes.html")
	if err != nil {
		// A missing template is our own packaging bug, not the backend's.
		log.Printf("cannot parse the fortunes template: %v", err)
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	if err := tmpl.Execute(w, fortunes); err != nil {
		log.Printf("cannot render the fortunes template: %v", err)
	}
}

// AddHandler forwards a new fortune to the backend.
func AddHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Use POST", http.StatusMethodNotAllowed)
		return
	}

	f := new(newFortune)
	if err := json.NewDecoder(r.Body).Decode(f); err != nil {
		http.Error(w, "Send a json body with a message field", http.StatusBadRequest)
		return
	}

	postURL := fmt.Sprintf("%s/fortunes", backendBaseURL)
	payload, err := json.Marshal(fortune{
		ID:      fmt.Sprintf("%d", rand.Intn(10000)),
		Message: f.Message,
	})
	if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	resp, err := myClient.Post(postURL, "application/json", bytes.NewBuffer(payload))
	if err != nil {
		backendUnavailable(w, "adding a fortune", err)
		return
	}
	defer resp.Body.Close()

	// The backend answers 503 when it cannot write to Redis. Passing that
	// through matters: telling someone "Cookie added!" for a cookie that was
	// never stored is the exact thing 04-database was about.
	if resp.StatusCode != http.StatusOK {
		backendUnavailable(w, "adding a fortune",
			fmt.Errorf("backend answered %d", resp.StatusCode))
		return
	}

	fmt.Fprint(w, "Cookie added!")
}

func main() {
	http.Handle("/healthz", instrument("healthz", http.HandlerFunc(HealthzHandler)))
	http.Handle("/api/random", instrument("api_random", http.HandlerFunc(RandomHandler)))
	http.Handle("/api/all", instrument("api_all", http.HandlerFunc(AllHandler)))
	http.Handle("/api/add", instrument("api_add", http.HandlerFunc(AddHandler)))
	http.Handle("/metrics", metricsHandler())
	http.Handle("/", instrument("static", http.FileServer(http.Dir("./static"))))

	err := http.ListenAndServe(":8080", nil)
	fmt.Printf("%v\n", err)
}
