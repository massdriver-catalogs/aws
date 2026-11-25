// proxy serves several local automations behind one tunnel: a request to
// /<name>/... goes to that automation's port, without the prefix. ngrok's free
// plan runs at most three endpoints, and there are more automations than that.
//
//	go run proxy.go 8080 statuspage=18081 drift=18082
package main

import (
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
)

func main() {
	if len(os.Args) < 3 {
		log.Fatal("usage: proxy <port> <name>=<port>...")
	}
	mux := http.NewServeMux()
	for _, route := range os.Args[2:] {
		name, port, ok := strings.Cut(route, "=")
		if !ok {
			log.Fatalf("route %q is not <name>=<port>", route)
		}
		target := &url.URL{Scheme: "http", Host: "127.0.0.1:" + port}
		mux.Handle("/"+name+"/", http.StripPrefix("/"+name, httputil.NewSingleHostReverseProxy(target)))
	}
	log.Fatal(http.ListenAndServe("127.0.0.1:"+os.Args[1], mux))
}
