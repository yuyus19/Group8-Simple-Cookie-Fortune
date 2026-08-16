package main

import (
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	"github.com/gomodule/redigo/redis"
)

var dbPool *redis.Pool
var usingRedis = false

// newRedisPool builds the connection pool.
//
// This used to be one long lived redis.Conn shared by every request, which had
// two problems. A redigo connection is not safe for concurrent use, so two
// requests at once could interleave and garble the protocol, and once that
// single connection dropped it stayed dropped for the life of the process. So
// if Redis restarted, the backend never came back on its own.
//
// A pool fixes both. Each request borrows a connection and gives it back, and
// a broken one is replaced on the next dial. That is what makes the "database
// becomes unavailable" case in 05-bon-appetit recover by itself, and it is
// also what makes it safe to run more than one backend replica.
func newRedisPool(addr string) *redis.Pool {
	return &redis.Pool{
		MaxIdle:     4,
		MaxActive:   16,
		IdleTimeout: 240 * time.Second,
		Wait:        true,
		Dial: func() (redis.Conn, error) {
			return redis.Dial("tcp", addr,
				redis.DialConnectTimeout(3*time.Second),
				redis.DialReadTimeout(3*time.Second),
				redis.DialWriteTimeout(3*time.Second),
			)
		},
		// Without this a request can be handed a connection that quietly died
		// while it was sitting idle in the pool.
		TestOnBorrow: func(c redis.Conn, since time.Time) error {
			if time.Since(since) < time.Minute {
				return nil
			}
			_, err := c.Do("PING")
			return err
		},
	}
}

// redisDo runs a single command on a borrowed connection.
func redisDo(command string, args ...interface{}) (interface{}, error) {
	if !usingRedis || dbPool == nil {
		return nil, fmt.Errorf("redis is not configured")
	}
	conn := dbPool.Get()
	defer conn.Close()
	return conn.Do(command, args...)
}

func init() {
	// Check if REDIS_DNS environment variable is set
	if os.Getenv("REDIS_DNS") == "" {
		fmt.Println("redis config not set")
		return
	}

	addr := fmt.Sprintf("%s:6379", getEnv("REDIS_DNS", "localhost"))
	dbPool = newRedisPool(addr)

	for i := 0; i < 5; i++ {
		conn := dbPool.Get()
		_, err := conn.Do("PING")
		conn.Close()
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

	resKeys, err := redis.Values(redisDo("hkeys", "fortunes"))
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
			if _, err := redisDo("hset", "fortunes", id, f.Message); err != nil {
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
		val, err := redisDo("hget", "fortunes", key)
		if err != nil {
			fmt.Println("redis hget failed", err.Error())
		} else {
			idx := string(key.([]byte))
			msg := string(val.([]byte))
			datastoreDefault.m[idx] = fortune{ID: idx, Message: msg}
			fmt.Printf("%s => %s\n", key, val)
		}
	}
}
