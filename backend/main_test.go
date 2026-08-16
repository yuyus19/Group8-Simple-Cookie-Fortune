package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// Each test gets its own store. The handlers hang off a shared package level
// datastoreDefault otherwise, and one test adding a fortune would change what
// the next one sees.
func newTestHandler() *fortuneHandler {
	return &fortuneHandler{
		store: &datastore{
			m: map[string]fortune{
				"1": {ID: "1", Message: "A new voyage will fill your life with untold memories."},
				"2": {ID: "2", Message: "It ain't over till it's EOF."},
			},
			RWMutex: &sync.RWMutex{},
		},
	}
}

func TestHealthz(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rr := httptest.NewRecorder()

	http.HandlerFunc(HealthzHandler).ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("status: got %d want %d", rr.Code, http.StatusOK)
	}
	if got := rr.Body.String(); got != "healthy" {
		t.Errorf("body: got %q want %q", got, "healthy")
	}
}

func TestListFortunes(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/fortunes", nil)
	rr := httptest.NewRecorder()

	newTestHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status: got %d want %d", rr.Code, http.StatusOK)
	}

	var got []fortune
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("response is not valid json: %v", err)
	}
	if len(got) != 2 {
		t.Errorf("expected 2 fortunes, got %d", len(got))
	}
}

func TestGetFortune(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/fortunes/1", nil)
	rr := httptest.NewRecorder()

	newTestHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status: got %d want %d", rr.Code, http.StatusOK)
	}

	var got fortune
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("response is not valid json: %v", err)
	}
	if got.ID != "1" {
		t.Errorf("id: got %q want %q", got.ID, "1")
	}
}

func TestGetFortuneNotFound(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/fortunes/4242", nil)
	rr := httptest.NewRecorder()

	newTestHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("status: got %d want %d", rr.Code, http.StatusNotFound)
	}
}

func TestRandomFortune(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/fortunes/random", nil)
	rr := httptest.NewRecorder()

	newTestHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status: got %d want %d", rr.Code, http.StatusOK)
	}

	var got fortune
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("response is not valid json: %v", err)
	}
	if got.Message == "" {
		t.Error("expected a message, got an empty one")
	}
}

func TestCreateFortune(t *testing.T) {
	h := newTestHandler()

	body := strings.NewReader(`{"id":"99","message":"Written by a test."}`)
	req := httptest.NewRequest(http.MethodPost, "/fortunes", body)
	rr := httptest.NewRecorder()

	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status: got %d want %d", rr.Code, http.StatusOK)
	}

	// It must actually be readable afterwards, not just accepted.
	readBack := httptest.NewRequest(http.MethodGet, "/fortunes/99", nil)
	rr2 := httptest.NewRecorder()
	h.ServeHTTP(rr2, readBack)

	if rr2.Code != http.StatusOK {
		t.Fatalf("reading it back: got %d want %d", rr2.Code, http.StatusOK)
	}

	var got fortune
	if err := json.Unmarshal(rr2.Body.Bytes(), &got); err != nil {
		t.Fatalf("response is not valid json: %v", err)
	}
	if got.Message != "Written by a test." {
		t.Errorf("message: got %q want %q", got.Message, "Written by a test.")
	}
}

func TestUnknownPathIsNotFound(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/nope", nil)
	rr := httptest.NewRecorder()

	newTestHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("status: got %d want %d", rr.Code, http.StatusNotFound)
	}
}
