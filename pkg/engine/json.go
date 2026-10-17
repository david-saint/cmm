package engine

import (
	"bytes"
	"encoding/json"

	"github.com/david-saint/cmm/pkg/rules"
)

// JSON renders the plan in the stable, versioned format read by other tools (see SchemaVersion and
// testdata/plan_v1.golden.json): two-space indented, one trailing newline, empty lists as [] never null.
func (p *Plan) JSON() ([]byte, error) {
	out := *p // do not mutate the caller's plan
	if out.Items == nil {
		out.Items = []rules.Candidate{}
	}
	if out.Groups == nil {
		out.Groups = []Group{}
	}
	if out.Skipped == nil {
		out.Skipped = []rules.Skip{}
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false) // paths and notes are data, not HTML
	if err := enc.Encode(&out); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
