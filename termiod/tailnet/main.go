// termio-tailnet puts termiod on the user's tailnet as a device of its own,
// with Tailscale's tsnet library, so the box needs no Tailscale install.
//
// termiod starts it and owns it. The helper speaks to termiod in two ways:
// every state change is one JSON line on stdout, and every connection it
// accepts is piped, byte for byte, to termiod's tailnet socket. It never reads
// the session protocol. Only the Tailscale user who owns this node gets in:
// tsnet's WhoIs names the caller before a byte is forwarded.
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/types/views"
)

// PlainPort is the port the helper answers on, unencrypted at the TLS layer,
// on the node's own tailnet addresses. WireGuard already encrypts it. It is
// what makes pairing work on a tailnet with HTTPS certificates turned off.
const PlainPort = 8790

type status struct {
	State   string   `json:"state"`
	AuthURL string   `json:"auth_url,omitempty"`
	DNSName string   `json:"dns_name,omitempty"`
	IPs     []string `json:"ips,omitempty"`
	HTTPS   bool     `json:"https"`
	Owner   string   `json:"owner,omitempty"`
	Tagged  bool     `json:"tagged,omitempty"`
	Tailnet string   `json:"tailnet,omitempty"`
	Message string   `json:"message,omitempty"`
}

var emit = func() func(status) {
	var mu sync.Mutex
	var last string
	encoder := json.NewEncoder(os.Stdout)
	return func(s status) {
		mu.Lock()
		defer mu.Unlock()
		line, _ := json.Marshal(s)
		if string(line) == last {
			return
		}
		last = string(line)
		if err := encoder.Encode(s); err != nil {
			log.Printf("writing status: %v", err)
		}
	}
}()

func main() {
	log.SetFlags(0)
	log.SetPrefix("termio-tailnet: ")
	if len(os.Args) < 2 {
		log.Fatal("usage: termio-tailnet serve|logout --dir DIR ...")
	}
	switch os.Args[1] {
	case "serve":
		serve(os.Args[2:])
	case "logout":
		logout(os.Args[2:])
	case "version":
		fmt.Println(version())
	default:
		log.Fatalf("unknown command %q", os.Args[1])
	}
}

func newServer(arguments []string, name string) (*tsnet.Server, *flag.FlagSet, map[string]*string) {
	flags := flag.NewFlagSet(name, flag.ExitOnError)
	values := map[string]*string{
		"dir":           flags.String("dir", "", "state directory (required)"),
		"hostname":      flags.String("hostname", "termio", "device name on the tailnet"),
		"forward":       flags.String("forward", "", "termiod's tailnet Unix socket"),
		"auth-key-file": flags.String("auth-key-file", "", "file holding a one-time auth key"),
	}
	_ = flags.Parse(arguments)
	if *values["dir"] == "" {
		log.Fatal("--dir is required")
	}
	server := &tsnet.Server{
		Dir:      *values["dir"],
		Hostname: *values["hostname"],
		// tsnet's own log is verbose and goes to stderr, which termiod keeps
		// in its log. The sign-in link reaches termiod through the status
		// line instead of this text.
		Logf: func(string, ...any) {},
		UserLogf: func(format string, arguments ...any) {
			// tsnet repeats the sign-in link every few seconds. It already
			// reached termiod in a status line.
			if strings.Contains(format, "To start this tsnet server") {
				return
			}
			log.Printf(format, arguments...)
		},
	}
	if path := *values["auth-key-file"]; path != "" {
		key, err := os.ReadFile(path)
		if err != nil {
			log.Fatalf("reading the auth key: %v", err)
		}
		server.AuthKey = strings.TrimSpace(string(key))
	}
	return server, flags, values
}

func serve(arguments []string) {
	server, _, values := newServer(arguments, "serve")
	forward := *values["forward"]
	if forward == "" {
		log.Fatal("--forward is required")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	emit(status{State: "starting"})
	if err := server.Start(); err != nil {
		emit(status{State: "error", Message: err.Error()})
		os.Exit(1)
	}
	defer server.Close()
	client, err := server.LocalClient()
	if err != nil {
		emit(status{State: "error", Message: err.Error()})
		os.Exit(1)
	}

	go acceptCommands(ctx, client, stop)

	plain, err := server.Listen("tcp", fmt.Sprintf(":%d", PlainPort))
	if err != nil {
		emit(status{State: "error", Message: err.Error()})
		os.Exit(1)
	}
	go acceptLoop(ctx, plain, client, forward)

	var secure sync.Once
	watchErr := watch(ctx, client, func(s status) {
		if s.State == "running" && s.HTTPS {
			secure.Do(func() {
				listener, err := server.ListenTLS("tcp", ":443")
				if err != nil {
					log.Printf("listening on 443: %v", err)
					return
				}
				go acceptLoop(ctx, listener, client, forward)
			})
		}
		emit(s)
	})
	if watchErr != nil && ctx.Err() == nil {
		emit(status{State: "error", Message: watchErr.Error()})
		os.Exit(1)
	}
}

// acceptCommands reads one word per line from termiod. Closing stdin is how
// termiod says it is gone, so the helper never outlives its daemon.
func acceptCommands(ctx context.Context, client *local.Client, stop context.CancelFunc) {
	buffer := make([]byte, 256)
	pending := ""
	for {
		n, err := os.Stdin.Read(buffer)
		pending += string(buffer[:n])
		for {
			index := strings.IndexByte(pending, '\n')
			if index < 0 {
				break
			}
			command := strings.TrimSpace(pending[:index])
			pending = pending[index+1:]
			switch command {
			case "logout":
				logoutContext, cancel := context.WithTimeout(ctx, 15*time.Second)
				if err := client.Logout(logoutContext); err != nil {
					log.Printf("signing out: %v", err)
				}
				cancel()
				emit(status{State: "logged_out"})
				stop()
				return
			case "login":
				if err := client.StartLoginInteractive(ctx); err != nil {
					log.Printf("starting sign-in: %v", err)
				}
			case "":
			default:
				log.Printf("unknown command %q", command)
			}
		}
		if err != nil {
			log.Printf("stopping: termiod closed its end (%v)", err)
			stop()
			return
		}
	}
}

func watch(ctx context.Context, client *local.Client, report func(status)) error {
	watcher, err := client.WatchIPNBus(ctx, ipn.NotifyInitialState|ipn.NotifyNoNetMap)
	if err != nil {
		return err
	}
	defer watcher.Close()
	authURL := ""
	askedForLogin := false
	for {
		notify, err := watcher.Next()
		if err != nil {
			return err
		}
		if notify.BrowseToURL != nil {
			authURL = *notify.BrowseToURL
		}
		if notify.ErrMessage != nil {
			report(status{State: "error", Message: *notify.ErrMessage})
		}
		if notify.State == nil && notify.BrowseToURL == nil && notify.SelfChange == nil {
			continue
		}
		current, err := client.StatusWithoutPeers(ctx)
		if err != nil {
			return err
		}
		switch current.BackendState {
		case ipn.NeedsLogin.String():
			if authURL == "" && !askedForLogin {
				askedForLogin = true
				if err := client.StartLoginInteractive(ctx); err != nil {
					log.Printf("starting sign-in: %v", err)
				}
			}
			report(status{State: "needs_login", AuthURL: authURL})
		case ipn.NeedsMachineAuth.String():
			report(status{State: "needs_approval"})
		case ipn.Running.String():
			authURL = ""
			s := status{State: "running", HTTPS: len(current.CertDomains) > 0}
			if self := current.Self; self != nil {
				s.DNSName = strings.TrimSuffix(self.DNSName, ".")
				for _, ip := range self.TailscaleIPs {
					s.IPs = append(s.IPs, ip.String())
				}
				s.Tagged = isTagged(self.Tags)
				if !s.Tagged {
					s.Owner = ownerLogin(ctx, client, current)
				}
			}
			if current.CurrentTailnet != nil {
				s.Tailnet = current.CurrentTailnet.Name
			}
			report(s)
		default:
			report(status{State: "starting"})
		}
	}
}

// ownerLogin names the account that owns this node. The first report after
// sign-in can come before the user profiles have, so it then asks WhoIs.
func ownerLogin(ctx context.Context, client *local.Client, current *ipnstate.Status) string {
	self := current.Self
	if profile, ok := current.User[self.UserID]; ok {
		return profile.LoginName
	}
	if len(self.TailscaleIPs) == 0 {
		return ""
	}
	lookup, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	who, err := client.WhoIs(lookup, self.TailscaleIPs[0].String())
	if err != nil || who.UserProfile == nil {
		return ""
	}
	return who.UserProfile.LoginName
}

// isTagged takes the pointer itself: an untagged node's Tags is a nil
// *views.Slice, which an interface parameter would hide from a nil check.
func isTagged(tags *views.Slice[string]) bool {
	return tags != nil && tags.Len() > 0
}

func acceptLoop(ctx context.Context, listener net.Listener, client *local.Client, forward string) {
	go func() {
		<-ctx.Done()
		listener.Close()
	}()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return
			}
			log.Printf("accepting: %v", err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go handle(ctx, conn, client, forward)
	}
}

// handle admits a caller only when it is a device signed in as the same
// Tailscale user who owns this node. A tagged node has no owner, so it admits
// nobody, the same rule Rex applies.
func handle(ctx context.Context, conn net.Conn, client *local.Client, forward string) {
	defer conn.Close()
	whoisContext, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	remote := conn.RemoteAddr().String()
	caller, err := client.WhoIs(whoisContext, remote)
	if err != nil {
		log.Printf("refused %s: unknown caller: %v", remote, err)
		return
	}
	current, err := client.StatusWithoutPeers(whoisContext)
	if err != nil || current.Self == nil {
		log.Printf("refused %s: reading this node: %v", remote, err)
		return
	}
	if isTagged(current.Self.Tags) {
		log.Printf("refused %s: this node is tagged, so it has no owner", remote)
		return
	}
	if caller.Node == nil || caller.Node.IsTagged() || caller.UserProfile == nil ||
		caller.UserProfile.ID != tailcfg.UserID(current.Self.UserID) {
		name := "a tagged device"
		if caller.UserProfile != nil && caller.Node != nil && !caller.Node.IsTagged() {
			name = caller.UserProfile.LoginName
		}
		log.Printf("refused %s: %s is not this node's owner", remote, name)
		return
	}

	upstream, err := net.Dial("unix", forward)
	if err != nil {
		log.Printf("reaching termiod: %v", err)
		return
	}
	defer upstream.Close()
	pipe(conn, upstream)
}

func pipe(a, b net.Conn) {
	var group sync.WaitGroup
	group.Add(2)
	copyHalf := func(destination, source net.Conn) {
		defer group.Done()
		_, err := io.Copy(destination, source)
		if err != nil && !errors.Is(err, net.ErrClosed) {
			log.Printf("forwarding: %v", err)
		}
		switch half := destination.(type) {
		case *net.UnixConn:
			_ = half.CloseWrite()
		case *tls.Conn:
			_ = half.CloseWrite()
		case interface{ CloseWrite() error }:
			_ = half.CloseWrite()
		default:
			_ = destination.Close()
		}
	}
	go copyHalf(a, b)
	go copyHalf(b, a)
	group.Wait()
}

func logout(arguments []string) {
	server, _, _ := newServer(arguments, "logout")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := server.Start(); err != nil {
		log.Fatal(err)
	}
	defer server.Close()
	client, err := server.LocalClient()
	if err != nil {
		log.Fatal(err)
	}
	if err := client.Logout(ctx); err != nil {
		log.Fatal(err)
	}
}

func version() string {
	return "termio-tailnet (tailscale.com v1.104.2)"
}
