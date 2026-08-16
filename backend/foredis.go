package main

import (
	"fmt"
	"github.com/gomodule/redigo/redis"
	"log"
	"sync"
	"time"
	"os"
)

var dbLink redis.Conn
var usingRedis = false

func init() {
	// Check if REDIS_DNS environment variable is set
	if os.Getenv("REDIS_DNS") == "" {
		fmt.Println("redis config not set")
		return
	}
	var err error
	for i := 0; i < 5; i++ {
		dbLink, err = redis.Dial("tcp", fmt.Sprintf("%s:6379", getEnv("REDIS_DNS", "localhost")))
		if err == nil {
			usingRedis = true
			break
		}
		log.Printf("Attempt %d: redis connection failed: %s", i+1, err)
		time.Sleep(2 * time.Second)
	}

	if !usingRedis {
		log.Println("Failed to connect to redis after 5 attempts")
		return
	}

	resKeys, err := redis.Values(dbLink.Do("hkeys", "fortunes"))
	if err != nil {
		fmt.Println("redis hkeys failed", err.Error())
		return
	}

	// A Redis that has never been written to has no "fortunes" hash at all.
	// Falling through to the loop below would swap the built in fortunes for
	// an empty map, which is why a freshly deployed environment served
	// nothing until somebody posted a fortune by hand. Seed Redis from the
	// built in set instead, and return with datastoreDefault left alone --
	// it already holds exactly what was just written.
	if len(resKeys) == 0 {
		fmt.Printf("*** redis has no fortunes, seeding it with the built in set\n")
		for id, f := range datastoreDefault.m {
			if _, err := dbLink.Do("hset", "fortunes", id, f.Message); err != nil {
				fmt.Println("redis hset failed", err.Error())
				return
			}
			fmt.Printf("seeded %s => %s\n", id, f.Message)
		}
		return
	}

	datastoreDefault = datastore{m: map[string]fortune{}, RWMutex: &sync.RWMutex{}}
	fmt.Printf("*** loading redis fortunes:\n")
	for _, key := range resKeys {
		val, err := dbLink.Do("hget", "fortunes", key)
		if err != nil {
			fmt.Println("redis hget failed", err.Error())
		} else {
			idx := fmt.Sprintf("%s", key.([]byte))
			msg := fmt.Sprintf("%s", val.([]byte))
			datastoreDefault.m[idx] = fortune{ID: idx, Message: msg}
			fmt.Printf("%s => %s\n", key, val)
		}
	}
}
