package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// withStubBackend points the handlers at a fake backend for the duration of
// one test and puts the real value back afterwards. The handlers read
// backendBaseURL at call time, which is the whole reason it is a variable.
func withStubBackend(t *testing.T, h http.HandlerFunc) *httptest.Server {
	t.Helper()

	srv := httptest.NewServer(h)
	previous := backendBaseURL
	backendBaseURL = srv.URL

	t.Cleanup(func() {
		backendBaseURL = previous
		srv.Close()
	})

	return srv
}

func TestHealthz(t *testing.T) {

	// Create a request to pass to our handler. We don't have any query parameters for now, so we'll
	// pass 'nil' as the third parameter.
	req, err := http.NewRequest("GET", "/healthz", nil)
	if err != nil {
		t.Fatal(err)
	}

	// We create a ResponseRecorder (which satisfies http.ResponseWriter) to record the response.
	rr := httptest.NewRecorder()
	handler := http.HandlerFunc(HealthzHandler)

	// Our handlers satisfy http.Handler, so we can call their ServeHTTP method
	// directly and pass in our Request and ResponseRecorder.
	handler.ServeHTTP(rr, req)

	// Check the status code is what we expect.
	if status := rr.Code; status != http.StatusOK {
		t.Errorf("handler returned wrong status code: got %v want %v",
			status, http.StatusOK)
	}

	// Check the response body is what we expect.
	expected := "healthy"
	if rr.Body.String() != expected {
		t.Errorf("handler returned unexpected body: got %v want %v",
			rr.Body.String(), expected)
	}
}

func TestRandomHandler(t *testing.T) {
	withStubBackend(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/fortunes/random" {
			t.Errorf("backend path: got %q want %q", r.URL.Path, "/fortunes/random")
		}
		w.Header().Set("content-type", "application/json")
		w.Write([]byte(`{"id":"1","message":"It ain't over till it's EOF."}`))
	})

	rr := httptest.NewRecorder()
	RandomHandler(rr, httptest.NewRequest(http.MethodGet, "/api/random", nil))

	if rr.Code != http.StatusOK {
		t.Fatalf("status: got %d want %d", rr.Code, http.StatusOK)
	}
	if got := rr.Body.String(); got != "It ain't over till it's EOF." {
		t.Errorf("body: got %q", got)
	}
}

// The behaviour 05-bon-appetit asks for: pressing a button with the backend
// down must not take the frontend with it. Before the refactor this handler
// called log.Fatalln, so this test would have killed the test binary itself.
func TestRandomHandlerWhenBackendIsDown(t *testing.T) {
	srv := withStubBackend(t, func(w http.ResponseWriter, r *http.Request) {})
	srv.Close() // nothing is listening now

	rr := httptest.NewRecorder()
	RandomHandler(rr, httptest.NewRequest(http.MethodGet, "/api/random", nil))

	if rr.Code != http.StatusBadGateway {
		t.Errorf("status: got %d want %d", rr.Code, http.StatusBadGateway)
	}
	if !strings.Contains(rr.Body.String(), "unavailable") {
		t.Errorf("expected a helpful message, got %q", rr.Body.String())
	}
}

func TestAllHandler(t *testing.T) {
	withStubBackend(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "application/json")
		w.Write([]byte(`[{"id":"1","message":"first cookie"},{"id":"2","message":"second cookie"}]`))
	})

	rr := httptest.NewRecorder()
	AllHandler(rr, httptest.NewRequest(http.MethodGet, "/api/all", nil))

	if rr.Code != http.StatusOK {
		t.Fatalf("status: got %d want %d", rr.Code, http.StatusOK)
	}

	body := rr.Body.String()
	for _, want := range []string{"first cookie", "second cookie"} {
		if !strings.Contains(body, want) {
			t.Errorf("rendered page is missing %q, got %q", want, body)
		}
	}
}

func TestAllHandlerWhenBackendIsDown(t *testing.T) {
	srv := withStubBackend(t, func(w http.ResponseWriter, r *http.Request) {})
	srv.Close()

	rr := httptest.NewRecorder()
	AllHandler(rr, httptest.NewRequest(http.MethodGet, "/api/all", nil))

	if rr.Code != http.StatusBadGateway {
		t.Errorf("status: got %d want %d", rr.Code, http.StatusBadGateway)
	}
}

func TestAddHandler(t *testing.T) {
	var got string
	withStubBackend(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("backend method: got %q want POST", r.Method)
		}
		buf := make([]byte, r.ContentLength)
		r.Body.Read(buf)
		got = string(buf)
		w.Write([]byte(`{"id":"7","message":"from a test"}`))
	})

	body := strings.NewReader(`{"message":"from a test"}`)
	rr := httptest.NewRecorder()
	AddHandler(rr, httptest.NewRequest(http.MethodPost, "/api/add", body))

	if rr.Code != http.StatusOK {
		t.Fatalf("status: got %d want %d", rr.Code, http.StatusOK)
	}
	if rr.Body.String() != "Cookie added!" {
		t.Errorf("body: got %q want %q", rr.Body.String(), "Cookie added!")
	}
	if !strings.Contains(got, "from a test") {
		t.Errorf("the backend did not receive the message, got %q", got)
	}
}

func TestAddHandlerRejectsGet(t *testing.T) {
	rr := httptest.NewRecorder()
	AddHandler(rr, httptest.NewRequest(http.MethodGet, "/api/add", nil))

	if rr.Code != http.StatusMethodNotAllowed {
		t.Errorf("status: got %d want %d", rr.Code, http.StatusMethodNotAllowed)
	}
}

// When the backend cannot store the fortune it answers 503. The frontend must
// pass that on rather than cheerfully reporting "Cookie added!" for something
// that was never saved.
func TestAddHandlerPassesOnBackendFailure(t *testing.T) {
	withStubBackend(t, func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "the fortune store is unavailable", http.StatusServiceUnavailable)
	})

	body := strings.NewReader(`{"message":"this will not be stored"}`)
	rr := httptest.NewRecorder()
	AddHandler(rr, httptest.NewRequest(http.MethodPost, "/api/add", body))

	if rr.Code == http.StatusOK {
		t.Fatal("the frontend reported success for a fortune the backend refused")
	}
	if rr.Code != http.StatusBadGateway {
		t.Errorf("status: got %d want %d", rr.Code, http.StatusBadGateway)
	}
}
