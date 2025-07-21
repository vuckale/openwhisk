package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"time"
)

const (
	dockerSock    = "/var/run/docker.sock"
	imageName     = "vuckale/mobilenet-oc-l"

	actionDocker  = "mobilenet_docker"
	actionWasm    = "mobilenet_wasm"

	listenAddr    = ":8080"
	maxBody       = 10 << 20

	bgPingTimeout = 20 * time.Second // warm-up ping in goroutine
	livePingTime  = 1 * time.Second // 1 s health-check when ready
)

var (
	mu       sync.Mutex
	ready    bool
	pingInit bool
)

func setReady(v bool) { mu.Lock(); ready = v; mu.Unlock(); }

func getReady() bool  { mu.Lock(); defer mu.Unlock(); return ready }

func trySetPingInit() bool {
	mu.Lock()
	defer mu.Unlock()
	if pingInit {
		return false
	}
	pingInit = true
	return true
}

func clearPingInit() { mu.Lock(); pingInit = false; mu.Unlock() }

func containerRunning() bool {
	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
				return net.Dial("unix", dockerSock)
			},
		},
		Timeout: 500 * time.Millisecond,
	}
	url := fmt.Sprintf(
		"http://localhost/containers/json?filters={\"ancestor\":[\"%s\"]}",
		imageName,
	)
	resp, err := client.Get(url)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	var arr []map[string]any
	return json.NewDecoder(resp.Body).Decode(&arr) == nil && len(arr) > 0
}

func pingDocker(timeout time.Duration) bool {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	out, err := exec.CommandContext(ctx, "wsk", "action", "invoke",
		actionDocker, "-p", "ping", "true", "--blocking", "--result").Output()
	if err != nil || ctx.Err() != nil {
		return false
	}
	var res map[string]any
	return json.Unmarshal(out, &res) == nil && res["body"] == "pong"
}

func warmUpDockerAsync() {
	go func() {
		ok := pingDocker(bgPingTimeout)
		if ok {
			fmt.Println("[warm] pong → ready=true")
			setReady(true)
		} else {
			fmt.Println("[warm] ping failed")
		}
		clearPingInit()
	}()
}

func invokeHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}

	/* quick container-presence check */
	if !containerRunning() {
		setReady(false)
	}

	/* read request body into temp file */
	body, _ := io.ReadAll(io.LimitReader(r.Body, maxBody))
	_ = r.Body.Close()

	tmp, err := os.CreateTemp("", "params-*.json")
	if err != nil {
		http.Error(w, "tempfile: "+err.Error(), 500)
		return
	}
	defer os.Remove(tmp.Name())
	_, _ = tmp.Write(body)
	_ = tmp.Close()

	/* branch on readiness */
	action := actionWasm

	if !getReady() {
		fmt.Println("⏳ WASM path; scheduling warm-up")
		if trySetPingInit() {
			warmUpDockerAsync()
		}
	} else {
		/* quick 1-second health ping */
		// if pingDocker(livePingTime) {
		fmt.Println("DOCKER path")
		action = actionDocker
		// } else {
		// 	fmt.Println("Docker unhealthy → fallback to WASM")
		// 	setReady(false)
		// 	if trySetPingInit() {
		// 		warmUpDockerAsync()
		// 	}
		// }
	}

	out, err := exec.Command("wsk", "action", "invoke", action,
		"--param-file", tmp.Name(), "--result", "--blocking").CombinedOutput()
	if err != nil {
		http.Error(w, string(out), 500)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(out)
}

func main() {
	http.HandleFunc("/invoke", invokeHandler)
	fmt.Println("daemon listening on", listenAddr)
	if err := http.ListenAndServe(listenAddr, nil); err != nil {
		panic(err)
	}
}
