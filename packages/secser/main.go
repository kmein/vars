package main

import (
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

func main() {
	if len(os.Args) < 2 {
		log.Fatalf("Usage: secser <serve|send> ...")
	}
	cmd := os.Args[1]
	if cmd == "serve" {
		serve()
	} else if cmd == "send" {
		send()
	} else {
		log.Fatalf("Unknown command: %s", cmd)
	}
}

func serve() {
	sockPath := "/run/secser/secser.sock"
	outDir := "/var/lib/secser"

	// These might fail if unprivileged, but systemd creates them via StateDirectory/RuntimeDirectory
	os.MkdirAll(outDir, 0700)
	os.MkdirAll(filepath.Dir(sockPath), 0755)
	os.Remove(sockPath)

	addr, err := net.ResolveUnixAddr("unix", sockPath)
	if err != nil {
		log.Fatal(err)
	}
	listener, err := net.ListenUnix("unix", addr)
	if err != nil {
		log.Fatal(err)
	}
	defer listener.Close()
	os.Chmod(sockPath, 0666)

	log.Printf("secser listening on %s", sockPath)

	for {
		conn, err := listener.AcceptUnix()
		if err != nil {
			log.Printf("Accept error: %v", err)
			continue
		}
		go handleConnection(conn, outDir)
	}
}

func handleConnection(conn *net.UnixConn, outDir string) {
	defer conn.Close()

	buf := make([]byte, 1024)
	oob := make([]byte, 1024)
	n, oobn, _, _, err := conn.ReadMsgUnix(buf, oob)
	if err != nil && err != io.EOF {
		log.Printf("ReadMsgUnix error: %v", err)
		return
	}

	scms, err := syscall.ParseSocketControlMessage(oob[:oobn])
	if err != nil || len(scms) == 0 {
		log.Printf("Failed to parse socket control message: %v", err)
		return
	}

	fds, err := syscall.ParseUnixRights(&scms[0])
	if err != nil || len(fds) == 0 {
		log.Printf("Failed to parse unix rights: %v", err)
		return
	}
	fd := fds[0]
	defer syscall.Close(fd)

	fdPath := fmt.Sprintf("/proc/self/fd/%d", fd)
	realPath, err := os.Readlink(fdPath)
	if err != nil {
		log.Printf("Failed to readlink %s: %v", fdPath, err)
		return
	}

	log.Printf("Received FD resolving to: %s", realPath)

	drvName := parseDrvName(realPath)
	if drvName == "" {
		log.Printf("Could not parse derivation name from path: %s", realPath)
		return
	}

	outFile := filepath.Join(outDir, drvName)
	f, err := os.OpenFile(outFile, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		log.Printf("Failed to open output file: %v", err)
		return
	}
	defer f.Close()

	if n > 1 {
		f.Write(buf[1:n]) // skip the 1-byte dummy payload used for SCM_RIGHTS
	}
	io.Copy(f, conn)
	log.Printf("Successfully wrote secret for %s to %s", drvName, outFile)
}

func parseDrvName(p string) string {
	parts := strings.Split(p, "/")
	for _, part := range parts {
		if strings.HasPrefix(part, "nix-build-") {
			s := strings.TrimPrefix(part, "nix-build-")
			if idx := strings.LastIndex(s, ".drv-"); idx != -1 {
				return s[:idx]
			}
		}
	}
	if strings.HasPrefix(p, "/nix/store/") && len(parts) >= 4 {
		storePart := parts[3]
		if len(storePart) > 33 && storePart[32] == '-' {
			return storePart[33:]
		}
	}
	return ""
}

func send() {
	if len(os.Args) < 3 {
		log.Fatalf("Usage: secser send <proof-file>")
	}
	proofFile := os.Args[2]

	f, err := os.Open(proofFile)
	if err != nil {
		log.Fatalf("Failed to open proof file: %v", err)
	}
	defer f.Close()

	sockPath := "/run/secser/secser.sock"
	addr, err := net.ResolveUnixAddr("unix", sockPath)
	if err != nil {
		log.Fatalf("Resolve error: %v", err)
	}
	conn, err := net.DialUnix("unix", nil, addr)
	if err != nil {
		log.Fatalf("Dial error: %v", err)
	}
	defer conn.Close()

	rights := syscall.UnixRights(int(f.Fd()))
	_, _, err = conn.WriteMsgUnix([]byte{0}, rights, nil)
	if err != nil {
		log.Fatalf("WriteMsgUnix error: %v", err)
	}

	_, err = io.Copy(conn, os.Stdin)
	if err != nil {
		log.Fatalf("Copy error: %v", err)
	}
}
