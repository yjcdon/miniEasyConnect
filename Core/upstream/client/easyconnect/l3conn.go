package easyconnect

import (
	"io"
	"net"
	"sync"

	"github.com/mythologyli/zju-connect/log"
)

type L3Conn struct {
	easyConnectClient *Client

	sendConn io.WriteCloser
	sendLock sync.Mutex

	recvConn io.ReadCloser
	recvLock sync.Mutex
	mu       sync.Mutex
	closed   bool
}

// Read reconnects a failed receive stream at most four times per read.
func (c *L3Conn) Read(p []byte) (n int, err error) {
	c.recvLock.Lock()
	defer c.recvLock.Unlock()
	for attempt := 0; attempt < 5; attempt++ {
		c.mu.Lock()
		conn, closed := c.recvConn, c.closed
		c.mu.Unlock()
		if closed {
			return 0, net.ErrClosed
		}
		n, err = conn.Read(p)
		if err == nil || n > 0 {
			return n, nil
		}
		c.mu.Lock()
		closed = c.closed
		c.mu.Unlock()
		if closed {
			return 0, net.ErrClosed
		}
		if c.easyConnectClient.lifecycleCtx.Err() != nil {
			return 0, c.easyConnectClient.lifecycleCtx.Err()
		}
		if attempt == 4 {
			return 0, err
		}
		_ = conn.Close()
		replacement, reconnectErr := c.easyConnectClient.RecvConn()
		if reconnectErr != nil {
			return 0, reconnectErr
		}
		c.mu.Lock()
		if c.closed {
			c.mu.Unlock()
			_ = replacement.Close()
			return 0, net.ErrClosed
		}
		c.recvConn = replacement
		c.mu.Unlock()
	}
	return
}

// Write retries only when no payload was written, avoiding duplicated stream data.
func (c *L3Conn) Write(p []byte) (n int, err error) {
	c.sendLock.Lock()
	defer c.sendLock.Unlock()
	for attempt := 0; attempt < 5; attempt++ {
		c.mu.Lock()
		conn, closed := c.sendConn, c.closed
		c.mu.Unlock()
		if closed {
			return 0, net.ErrClosed
		}
		n, err = conn.Write(p)
		if err == nil || n > 0 {
			return n, err
		}
		c.mu.Lock()
		closed = c.closed
		c.mu.Unlock()
		if closed {
			return 0, net.ErrClosed
		}
		if c.easyConnectClient.lifecycleCtx.Err() != nil {
			return 0, c.easyConnectClient.lifecycleCtx.Err()
		}
		if attempt == 4 {
			return 0, err
		}
		_ = conn.Close()
		replacement, reconnectErr := c.easyConnectClient.SendConn()
		if reconnectErr != nil {
			return 0, reconnectErr
		}
		c.mu.Lock()
		if c.closed {
			c.mu.Unlock()
			_ = replacement.Close()
			return 0, net.ErrClosed
		}
		c.sendConn = replacement
		c.mu.Unlock()
	}
	return
}

// Close interrupts active I/O without waiting for a read or write lock.
func (c *L3Conn) Close() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	send, recv := c.sendConn, c.recvConn
	c.mu.Unlock()
	if send != nil {
		_ = send.Close()
	}
	if recv != nil {
		_ = recv.Close()
	}
	return nil
}

func (c *Client) NewL3Conn() (io.ReadWriteCloser, error) {
	conn := &L3Conn{
		easyConnectClient: c,
	}

	var err error
	conn.sendConn, err = c.SendConn()
	if err != nil {
		log.Printf("Error occurred while creating sendConn: %v", err)
		return nil, err
	}

	conn.recvConn, err = c.RecvConn()
	if err != nil {
		log.Printf("Error occurred while creating recvConn: %v", err)
		_ = conn.Close()
		return nil, err
	}
	return conn, nil
}
