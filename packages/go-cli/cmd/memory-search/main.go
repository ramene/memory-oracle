// memory-search (Go) — supersession-aware BM25 retrieval over the FTS5 index.
//
// Compiles to a single static binary, zero runtime deps beyond libc.
// Reads the same SQLite index as the Node version: ~/.local/share/journal/.memory-index.db
//
// Usage matches the Node CLI:
//   memory-search "query" --budget=30000 --k=10 [--project=PROJECT] [--json]

package main

import (
	"database/sql"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	_ "modernc.org/sqlite"
)

// FTS5 treats punctuation as syntax. Sanitize user queries by splitting on non-word
// characters, then quoting each surviving token. Equivalent to Node version's behavior.
var nonWord = regexp.MustCompile(`[^\p{L}\p{N}_]+`)

func sanitizeFTS(q string) string {
	tokens := nonWord.Split(q, -1)
	var quoted []string
	for _, t := range tokens {
		if t == "" {
			continue
		}
		quoted = append(quoted, `"`+t+`"`)
	}
	return strings.Join(quoted, " ")
}

type hit struct {
	Project     string
	File        string
	Name        string
	Description string
	MergedBody  string
	HasSup      int
	Rank        float64
}

func main() {
	var (
		budget    = flag.Int("budget", 30000, "byte budget for total output")
		k         = flag.Int("k", 10, "top-K hits")
		project   = flag.String("project", "", "filter to project")
		jsonOut   = flag.Bool("json", false, "JSON output (not implemented yet)")
		dbPath    = flag.String("db", "", "override index path")
	)

	// Reorder os.Args so flags can appear AFTER positional query terms.
	// Go's default flag.Parse() stops at first non-flag arg; that's surprising to users
	// who type `memory-search "my query" --budget=3000`. Pull --flags to the front.
	flags, positional := []string{os.Args[0]}, []string{}
	for _, a := range os.Args[1:] {
		if strings.HasPrefix(a, "-") {
			flags = append(flags, a)
		} else {
			positional = append(positional, a)
		}
	}
	os.Args = append(flags, positional...)
	flag.Parse()
	_ = jsonOut

	query := strings.Join(flag.Args(), " ")
	if query == "" {
		fmt.Fprintln(os.Stderr, "usage: memory-search [flags] <query terms>")
		os.Exit(2)
	}

	if *dbPath == "" {
		home, _ := os.UserHomeDir()
		*dbPath = filepath.Join(home, ".local", "share", "journal", ".memory-index.db")
	}

	db, err := sql.Open("sqlite", *dbPath+"?mode=ro&_pragma=journal_mode(WAL)")
	if err != nil {
		fmt.Fprintln(os.Stderr, "open db:", err)
		os.Exit(1)
	}
	defer db.Close()

	// FTS5 query — use bm25() for rank, allow project filter via JOIN
	q := `SELECT mf.project, mf.file, mf.name, mf.description, mf.merged_body, mf.has_supersessions, bm25(memory_fts) AS rank
	      FROM memory_fts
	      JOIN memory_file mf ON mf.id = memory_fts.rowid
	      WHERE memory_fts MATCH ?`
	args := []any{sanitizeFTS(query)}
	if *project != "" {
		q += ` AND mf.project = ?`
		args = append(args, *project)
	}
	q += ` ORDER BY rank LIMIT ?`
	args = append(args, *k)

	rows, err := db.Query(q, args...)
	if err != nil {
		fmt.Fprintln(os.Stderr, "query:", err)
		os.Exit(1)
	}
	defer rows.Close()

	var hits []hit
	for rows.Next() {
		var h hit
		if err := rows.Scan(&h.Project, &h.File, &h.Name, &h.Description, &h.MergedBody, &h.HasSup, &h.Rank); err != nil {
			fmt.Fprintln(os.Stderr, "scan:", err)
			continue
		}
		hits = append(hits, h)
	}

	// Render — budgeted output, format matches Node version
	fmt.Printf("# memory-search results for: %q\n", query)
	fmt.Printf("# Index: %s\n", *dbPath)

	bytesSoFar := 0
	rendered := 0
	for i, h := range hits {
		header := fmt.Sprintf("\n## %s/%s  %s\n**Name**: %s\n**Description**: %s\n**Rank (BM25)**: %.3f\n\n",
			h.Project, h.File, supBadge(h.HasSup), h.Name, h.Description, h.Rank)
		body := h.MergedBody
		// Truncate body to fit remaining budget (first hit gets priority — keep it whole even if it exceeds budget)
		need := len(header) + len(body) + 4
		if bytesSoFar+need > *budget && rendered > 0 {
			break
		}
		if bytesSoFar+need > *budget && rendered == 0 {
			body = body[:max(0, *budget-bytesSoFar-len(header)-100)] + "\n\n[... truncated to fit budget ...]"
		}
		fmt.Print(header)
		fmt.Println(body)
		fmt.Println("\n---")
		bytesSoFar += need
		rendered++
		_ = i
	}
	if rendered == 0 {
		fmt.Printf("# (no hits — corpus may not contain relevant content; try broader keywords)\n")
	} else {
		fmt.Printf("\n# Returned %d/%d hits, ~%d bytes (budget %d)\n", rendered, len(hits), bytesSoFar, *budget)
	}
}

func supBadge(has int) string {
	if has > 0 {
		return "⚠ HAS SUPERSESSIONS"
	}
	return ""
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
