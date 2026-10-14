package sys

import (
	"path/filepath"
	"testing"
	"time"
)

func TestNormalizeTmpDir(t *testing.T) {
	cases := []struct {
		in      string
		want    string
		wantErr bool
	}{
		{"/var/folders/nf/yhrg12y577l4g_v2yv61snzw0000gn/T/", "/var/folders/nf/yhrg12y577l4g_v2yv61snzw0000gn/T", false},
		{"/var/folders/nf/yhrg12y577l4g_v2yv61snzw0000gn/T", "/var/folders/nf/yhrg12y577l4g_v2yv61snzw0000gn/T", false},
		{"", "", true},
		{"/tmp", "", true},
		{"/var/folders/nf/T", "", true},
		{"/var/folders/nf/abc/T/extra", "", true},
		{"/var/folders/nf/abc/Cache", "", true},
		{"/private/var/folders/nf/abc/T", "", true}, // getconf reports the /var form; never mix forms
		{"relative/path/T", "", true},
	}
	for _, c := range cases {
		got, err := NormalizeTmpDir(c.in)
		if (err != nil) != c.wantErr {
			t.Errorf("NormalizeTmpDir(%q) error = %v, wantErr %v", c.in, err, c.wantErr)
			continue
		}
		if got != c.want {
			t.Errorf("NormalizeTmpDir(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// DefaultEnv is the one place that reads the real machine; the test only reads (getconf, home dir).
func TestDefaultEnv(t *testing.T) {
	env, err := DefaultEnv()
	if err != nil {
		t.Fatalf("DefaultEnv() failed: %v", err)
	}
	if !filepath.IsAbs(env.Home) {
		t.Errorf("Home should be absolute, got %q", env.Home)
	}
	if _, err := NormalizeTmpDir(env.TmpDir); err != nil {
		t.Errorf("TmpDir %q should satisfy the per-user temp dir pattern: %v", env.TmpDir, err)
	}
	if _, ok := env.Runner.(ExecRunner); !ok {
		t.Errorf("the default runner should be an ExecRunner, got %T", env.Runner)
	}
	if d := time.Since(env.Clock()); d < -time.Minute || d > time.Minute {
		t.Errorf("the default clock should be close to now, off by %v", d)
	}
}

func TestEnv_ClockFallsBackToNow(t *testing.T) {
	var e Env
	if d := time.Since(e.Clock()); d < -time.Minute || d > time.Minute {
		t.Errorf("zero Env should use time.Now, off by %v", d)
	}
}

func TestEnv_ClockUsesInjectedNow(t *testing.T) {
	fixed := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	e := Env{Now: func() time.Time { return fixed }}
	if !e.Clock().Equal(fixed) {
		t.Errorf("Clock() should return the injected time")
	}
}
