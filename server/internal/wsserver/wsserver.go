// Package wsserver is the WebSocket transport in front of the hub. It owns
// sockets, framing and timeouts; it owns no protocol logic beyond that.
package wsserver

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"rc-signal/internal/hub"
	"rcprotocol"
)

type Config struct {
	Addr         string
	TLSCert      string
	TLSKey       string
	InsecureHTTP bool
	Logger       *slog.Logger
}

type Server struct {
	cfg  Config
	hub  *hub.Hub
	log  *slog.Logger
	http *http.Server
	up   websocket.Upgrader

	mu    sync.Mutex
	conns map[*conn]struct{}
}

const (
	writeWait    = 10 * time.Second
	pongWait     = 70 * time.Second
	pingInterval = 30 * time.Second
	sendQueue    = 64
)

func New(cfg Config, h *hub.Hub) *Server {
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	s := &Server{cfg: cfg, hub: h, log: cfg.Logger, conns: map[*conn]struct{}{}}
	s.up = websocket.Upgrader{
		HandshakeTimeout: 10 * time.Second,
		ReadBufferSize:   4096,
		WriteBufferSize:  4096,

		CheckOrigin: func(*http.Request) bool { return true },
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/ws", s.handleWS)
	s.http = &http.Server{
		Addr:              cfg.Addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	return s
}

type conn struct {
	ws     *websocket.Conn
	client *hub.Client
	out    chan []byte
	closeC chan struct{}
	once   sync.Once
}

func (c *conn) shutdown() {
	c.once.Do(func() { close(c.closeC) })
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	ws, err := s.up.Upgrade(w, r, nil)
	if err != nil {
		s.log.Warn("websocket upgrade failed", "err", err)
		return
	}
	ws.SetReadLimit(protocol.MaxFrameBytes)

	c := &conn{ws: ws, out: make(chan []byte, sendQueue), closeC: make(chan struct{})}
	s.mu.Lock()
	s.conns[c] = struct{}{}
	s.mu.Unlock()

	send := func(b []byte) {
		select {
		case c.out <- b:
		default:

			c.shutdown()
		}
	}
	closeFn := func(code int, msg string) {
		_ = ws.WriteControl(websocket.CloseMessage,
			websocket.FormatCloseMessage(code, msg), time.Now().Add(writeWait))
		c.shutdown()
	}
	c.client = s.hub.AddClient(send, closeFn)

	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); s.writeLoop(c) }()
	s.readLoop(c)
	c.shutdown()
	wg.Wait()

	s.hub.RemoveClient(c.client)
	_ = ws.Close()
	s.mu.Lock()
	delete(s.conns, c)
	s.mu.Unlock()
}

func (s *Server) readLoop(c *conn) {
	_ = c.ws.SetReadDeadline(time.Now().Add(pongWait))
	c.ws.SetPongHandler(func(string) error {
		return c.ws.SetReadDeadline(time.Now().Add(pongWait))
	})
	authDeadline := time.Now().Add(protocol.AuthTimeoutSec * time.Second)
	for {
		select {
		case <-c.closeC:
			return
		default:
		}
		typ, data, err := c.ws.ReadMessage()
		if err != nil {
			if !websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway) {
				s.log.Debug("read ended", "deviceId", c.client.DeviceID(), "err", err)
			}
			return
		}
		if typ != websocket.TextMessage {
			s.log.Warn("non-text frame rejected", "deviceId", c.client.DeviceID())
			return
		}
		_ = c.ws.SetReadDeadline(time.Now().Add(pongWait))
		s.hub.Handle(c.client, data)
		if c.client.DeviceID() == "" && time.Now().After(authDeadline) {
			s.log.Info("closing unauthenticated connection")
			_ = c.ws.WriteControl(websocket.CloseMessage,
				websocket.FormatCloseMessage(1008, "auth_timeout"), time.Now().Add(writeWait))
			return
		}
	}
}

func (s *Server) writeLoop(c *conn) {
	ping := time.NewTicker(pingInterval)
	defer ping.Stop()
	for {
		select {
		case <-c.closeC:
			_ = c.ws.SetWriteDeadline(time.Now().Add(writeWait))
			_ = c.ws.WriteMessage(websocket.CloseMessage,
				websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""))
			_ = c.ws.Close()
			return
		case b := <-c.out:
			_ = c.ws.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.ws.WriteMessage(websocket.TextMessage, b); err != nil {
				c.shutdown()
				_ = c.ws.Close()
				return
			}
		case <-ping.C:
			_ = c.ws.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.ws.WriteMessage(websocket.PingMessage, nil); err != nil {
				c.shutdown()
				_ = c.ws.Close()
				return
			}
		}
	}
}

func (s *Server) ListenAndServe() error {
	ln, err := net.Listen("tcp", s.cfg.Addr)
	if err != nil {
		return err
	}
	return s.Serve(ln)
}

func (s *Server) Serve(ln net.Listener) error {
	if s.cfg.InsecureHTTP {
		s.log.Warn("serving PLAINTEXT http — local testing only", "addr", ln.Addr().String())
		err := s.http.Serve(ln)
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
	s.log.Info("serving wss", "addr", ln.Addr().String())
	err := s.http.ServeTLS(ln, s.cfg.TLSCert, s.cfg.TLSKey)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func (s *Server) Shutdown(ctx context.Context) error {
	s.hub.Shutdown()
	s.mu.Lock()
	for c := range s.conns {
		c.shutdown()
	}
	s.mu.Unlock()
	return s.http.Shutdown(ctx)
}

func RunSweeper(ctx context.Context, h *hub.Hub) {
	t := time.NewTicker(hub.SweepInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			h.Sweep()
		}
	}
}
