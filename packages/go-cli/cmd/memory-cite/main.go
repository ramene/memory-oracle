// memory-cite (Go) — streams large JSONL session transcripts, fetches context
// around a line, timestamp, or grep match. Tier-1 → Tier-2 bridge.
//
// Same surface as the Node version, but a static binary that handles 10GB JSONL
// files without breaking a sweat (vs Node's 512MB V8 string limit).

package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

type entry struct {
	Line    int
	Raw     string
	Role    string
	TS      string
	Preview string
}

func main() {
	var (
		session  = flag.String("session", "", "Claude Code session UUID")
		line     = flag.Int("line", 0, "specific line number to fetch")
		grep     = flag.String("grep", "", "regex pattern to find")
		at       = flag.String("at", "", "ISO timestamp to anchor on")
		tail     = flag.Int("tail", 0, "return last N lines")
		context  = flag.Int("context", 20, "lines of surrounding context")
		first    = flag.Int("first", 5, "max grep hits to return")
		info     = flag.Bool("info", false, "session metadata only")
		root     = flag.String("root", "", "projects root (default ~/.claude/projects)")
	)
	flag.Parse()

	// Positional form: memory-cite <session>[#L<n>]
	if *session == "" && flag.NArg() > 0 {
		arg := flag.Arg(0)
		if i := strings.Index(arg, "#L"); i > 0 {
			*session = arg[:i]
			fmt.Sscanf(arg[i+2:], "%d", line)
		} else {
			*session = arg
		}
	}
	if *session == "" {
		fmt.Fprintln(os.Stderr, "usage: memory-cite [flags] <session_id>[#L<n>]")
		os.Exit(2)
	}

	if *root == "" {
		home, _ := os.UserHomeDir()
		*root = filepath.Join(home, ".claude", "projects")
	}

	path, err := findTranscript(*root, *session)
	if err != nil {
		fmt.Fprintln(os.Stderr, "no transcript found:", *session)
		os.Exit(3)
	}

	if *info {
		printInfo(path, *session)
		return
	}
	if *line > 0 {
		printBand(path, *session, *line, *context)
		return
	}
	if *grep != "" {
		printGrep(path, *session, *grep, *first)
		return
	}
	if *at != "" {
		printAt(path, *session, *at, *context)
		return
	}
	if *tail > 0 {
		printTail(path, *session, *tail)
		return
	}
	printFirstUsers(path, *session, 10)
}

func findTranscript(root, session string) (string, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return "", err
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		candidate := filepath.Join(root, e.Name(), session+".jsonl")
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("not found")
}

func openScanner(path string) (*bufio.Scanner, *os.File, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	s := bufio.NewScanner(f)
	s.Buffer(make([]byte, 64*1024), 16*1024*1024) // 16MB max line
	return s, f, nil
}

func summarize(line string) (role, ts, preview string) {
	var obj map[string]any
	if err := json.Unmarshal([]byte(line), &obj); err != nil {
		return "malformed", "", trunc(line, 200)
	}
	if t, ok := obj["timestamp"].(string); ok {
		ts = t
	}
	msg, _ := obj["message"].(map[string]any)
	if msg == nil {
		role, _ = obj["type"].(string)
		if role == "" {
			role = "system"
		}
		return
	}
	role, _ = msg["role"].(string)
	if msgTS, ok := msg["timestamp"].(string); ok && ts == "" {
		ts = msgTS
	}
	var text strings.Builder
	switch c := msg["content"].(type) {
	case string:
		text.WriteString(c)
	case []any:
		for _, part := range c {
			if p, ok := part.(map[string]any); ok {
				switch p["type"] {
				case "text":
					if t, ok := p["text"].(string); ok {
						text.WriteString(t)
					}
				case "tool_use":
					fmt.Fprintf(&text, "[tool_use: %v]", p["name"])
				case "tool_result":
					text.WriteString("[tool_result]")
				}
			}
		}
	}
	preview = trunc(strings.Join(strings.Fields(text.String()), " "), 400)
	return
}

func trunc(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

func fmtEntry(e entry) string {
	tsShort := "?"
	if e.TS != "" {
		tsShort = e.TS
		if len(tsShort) > 19 {
			tsShort = tsShort[:19] + "Z"
		}
	}
	return fmt.Sprintf("L%6d  %s  %-9s  %s", e.Line, tsShort, e.Role, e.Preview)
}

func printInfo(path, session string) {
	s, f, err := openScanner(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return
	}
	defer f.Close()

	n := 0
	var firstTS, lastTS string
	for s.Scan() {
		n++
		if strings.TrimSpace(s.Text()) == "" {
			continue
		}
		_, ts, _ := summarize(s.Text())
		if firstTS == "" && ts != "" {
			firstTS = ts
		}
		if ts != "" {
			lastTS = ts
		}
	}
	stat, _ := os.Stat(path)
	out := map[string]any{
		"session":  session,
		"path":     path,
		"size":     fmt.Sprintf("%.1f MB", float64(stat.Size())/1024/1024),
		"lines":    n,
		"first_ts": firstTS,
		"last_ts":  lastTS,
	}
	b, _ := json.MarshalIndent(out, "", "  ")
	fmt.Println(string(b))
}

func printBand(path, session string, target, ctx int) {
	s, f, err := openScanner(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return
	}
	defer f.Close()
	fmt.Printf("# memory-cite %s#L%d  (path=%s)\n", session, target, path)
	n := 0
	for s.Scan() {
		n++
		if strings.TrimSpace(s.Text()) == "" {
			continue
		}
		if n < target-ctx {
			continue
		}
		if n > target+ctx {
			break
		}
		role, ts, preview := summarize(s.Text())
		marker := "  "
		if n == target {
			marker = ">>"
		}
		fmt.Printf("%s %s\n", marker, fmtEntry(entry{Line: n, Role: role, TS: ts, Preview: preview}))
	}
}

func printGrep(path, session, pat string, first int) {
	re, err := regexp.Compile("(?i)" + pat)
	if err != nil {
		fmt.Fprintln(os.Stderr, "bad regex:", err)
		return
	}
	s, f, err := openScanner(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return
	}
	defer f.Close()
	hits := 0
	n := 0
	fmt.Printf("# memory-cite --session %s --grep %q (first %d)\n", session, pat, first)
	for s.Scan() {
		n++
		if !re.MatchString(s.Text()) {
			continue
		}
		role, ts, preview := summarize(s.Text())
		fmt.Println(fmtEntry(entry{Line: n, Role: role, TS: ts, Preview: preview}))
		hits++
		if hits >= first {
			break
		}
	}
}

func printAt(path, session, isoTS string, ctx int) {
	target, err := time.Parse(time.RFC3339, isoTS)
	if err != nil {
		fmt.Fprintln(os.Stderr, "bad timestamp:", err)
		return
	}
	s, f, err := openScanner(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return
	}
	defer f.Close()
	bestLine := -1
	bestDelta := math.MaxInt64
	n := 0
	for s.Scan() {
		n++
		_, tsStr, _ := summarize(s.Text())
		if tsStr == "" {
			continue
		}
		t, err := time.Parse(time.RFC3339, tsStr)
		if err != nil {
			continue
		}
		d := int(target.Sub(t).Abs().Seconds())
		if d < bestDelta {
			bestDelta = d
			bestLine = n
		}
	}
	if bestLine < 0 {
		fmt.Fprintln(os.Stderr, "no timestamped entries")
		return
	}
	fmt.Printf("# memory-cite --session %s --at %s  (nearest L%d, Δ=%ds)\n", session, isoTS, bestLine, bestDelta)
	printBand(path, session, bestLine, ctx)
}

func printTail(path, session string, tail int) {
	s, f, err := openScanner(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return
	}
	defer f.Close()
	ring := make([]entry, 0, tail+1)
	n := 0
	for s.Scan() {
		n++
		if strings.TrimSpace(s.Text()) == "" {
			continue
		}
		role, ts, preview := summarize(s.Text())
		ring = append(ring, entry{Line: n, Role: role, TS: ts, Preview: preview})
		if len(ring) > tail {
			ring = ring[1:]
		}
	}
	fmt.Printf("# memory-cite --session %s --tail %d\n", session, tail)
	for _, e := range ring {
		fmt.Println(fmtEntry(e))
	}
}

func printFirstUsers(path, session string, n int) {
	s, f, err := openScanner(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return
	}
	defer f.Close()
	fmt.Printf("# memory-cite %s\n# first %d user turns:\n", session, n)
	count, ln := 0, 0
	for s.Scan() {
		ln++
		if strings.TrimSpace(s.Text()) == "" {
			continue
		}
		role, ts, preview := summarize(s.Text())
		if role != "user" {
			continue
		}
		fmt.Println(fmtEntry(entry{Line: ln, Role: role, TS: ts, Preview: preview}))
		count++
		if count >= n {
			break
		}
	}
}
