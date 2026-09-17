package ratelimit

import (
	"testing"
	"time"
)

var (
	perMinute = Rule{"per_min", 6, time.Minute}
	perHour   = Rule{"per_hour", 60, time.Hour}
)

func TestTakeSpendsFromEveryBucketOrFromNone(t *testing.T) {
	l := New()
	now := time.Unix(1_800_000_000, 0)
	both := []Charge{{perMinute, "a"}, {perHour, "a"}}
	for i := 0; i < 6; i++ {
		if ok, _ := l.Take(now, both...); !ok {
			t.Fatalf("call %d refused inside the burst", i)
		}
	}
	ok, wait := l.Take(now, both...)
	if ok || wait != 10 {
		t.Fatalf("7th call in a minute = %v, retry after %d; want refused, 10 s", ok, wait)
	}
	if ok, _ := l.Take(now, Charge{perHour, "a"}); !ok {
		t.Fatal("a refused combined charge still spent from the hourly bucket")
	}
	if ok, _ := l.Take(now, Charge{perMinute, "b"}); !ok {
		t.Fatal("keys share a bucket")
	}
}

func TestTheSlowestBucketSetsTheWait(t *testing.T) {
	l := New()
	now := time.Unix(1_800_000_000, 0)
	both := []Charge{{perMinute, "a"}, {perHour, "a"}}
	calls, wait := 0, 0
	for ; calls < 200; calls++ {
		now = now.Add(10 * time.Second)
		var ok bool
		if ok, wait = l.Take(now, both...); !ok {
			break
		}
	}
	if calls < 60 || calls > 80 || wait < 1 || wait > 60 {
		t.Fatalf("one call every 10 s: refused after %d calls with retry %d; want the hourly bucket to stop it near 70", calls, wait)
	}
	if ok, _ := l.Take(now, Charge{perMinute, "a"}); !ok {
		t.Fatal("the per-minute bucket alone should still have tokens")
	}
}

func TestRoomAnswersLikeTakeWithoutSpending(t *testing.T) {
	l := New()
	now := time.Unix(1_800_000_000, 0)
	for i := 0; i < 100; i++ {
		if ok, _ := l.Room(now, Charge{perMinute, "a"}); !ok {
			t.Fatalf("Room refused on call %d although nothing was spent", i)
		}
	}
	for {
		if ok, _ := l.Take(now, Charge{perMinute, "a"}); !ok {
			break
		}
	}
	take, takeWait := l.Take(now, Charge{perMinute, "a"})
	room, roomWait := l.Room(now, Charge{perMinute, "a"})
	if take || room || takeWait != roomWait || roomWait < 1 {
		t.Fatalf("empty bucket: Take=%v/%d Room=%v/%d", take, takeWait, room, roomWait)
	}
}

func TestIdleBucketsAreEvicted(t *testing.T) {
	l := New()
	now := time.Unix(1_800_000_000, 0)
	for i := 0; i < 1000; i++ {
		l.Take(now, Charge{perMinute, string(rune('a'+i%26)) + time.Duration(i).String()})
	}
	if l.Len() != 1000 {
		t.Fatalf("buckets = %d, want 1000", l.Len())
	}
	l.Take(now.Add(2*time.Minute), Charge{perHour, "fresh"})
	if l.Len() != 1 {
		t.Fatalf("buckets after every per-minute bucket refilled = %d, want 1", l.Len())
	}
	l.Take(now.Add(4*time.Minute), Charge{perMinute, "x"})
	if l.Len() != 2 {
		t.Fatalf("an hourly bucket that has not refilled was evicted: %d buckets", l.Len())
	}
}
