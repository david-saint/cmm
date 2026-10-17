package engine

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/david-saint/cmm/pkg/rules"
	"github.com/david-saint/cmm/pkg/sys/systest"
)

// ---- the file journal ----

func newJournal(t *testing.T) (*FileJournal, *systest.Sandbox) {
	t.Helper()
	sb := systest.NewSandbox(t)
	return NewFileJournal(sb.Env.Home, sb.Env.Clock), sb
}

func readText(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func deletedResult(path string) Result {
	return Result{Item: cand("r", "G", path, 10), Status: StatusDeleted, FreedBytes: 10}
}

func TestStateDir_IsCmmsOwnAndNeverDevCleanups(t *testing.T) {
	if got := StateDir("/Users/x"); got != "/Users/x/.local/state/cmm" {
		t.Errorf("StateDir = %q", got)
	}
}

func TestFileJournal_RecordsDeletionsCommandsAndFailuresOneLineEach(t *testing.T) {
	j, sb := newJournal(t)
	p := sb.Home("lane-builds/a/node_modules")
	brew := rules.Candidate{Rule: "homebrew", Group: "Homebrew", Path: "homebrew: cleanup", Bytes: 5, Tier: rules.TierSafe, Action: rules.ActionCommand}
	for _, r := range []Result{
		deletedResult(p),
		{Item: brew, Status: StatusDeleted},
		{Item: cand("r", "G", sb.Home("x"), 1), Status: StatusFailed, Reason: "permission denied"},
	} {
		if err := j.Record(r); err != nil {
			t.Fatalf("Record(%+v) failed: %v", r, err)
		}
	}
	want := "2026-10-14 12:00:00 deleted " + p + "\n" +
		"2026-10-14 12:00:00 ran homebrew homebrew: cleanup\n" +
		"2026-10-14 12:00:00 FAILED " + sb.Home("x") + ": permission denied\n"
	if got := readText(t, j.LogPath()); got != want {
		t.Errorf("log =\n%s\nwant\n%s", got, want)
	}
}

func TestFileJournal_SkipsAndDryRunsLeaveNoTrace(t *testing.T) {
	j, sb := newJournal(t)
	for _, s := range []Status{StatusSkipped, StatusDryRun} {
		if err := j.Record(Result{Item: cand("r", "G", sb.Home("x"), 1), Status: s, Reason: "why"}); err != nil {
			t.Fatalf("Record(%s) failed: %v", s, err)
		}
	}
	if exists(StateDir(sb.Env.Home)) {
		t.Error("nothing happened to disk, so nothing may be written, not even the folder")
	}
}

func TestFileJournal_AppendsAndKeepsTheFilesPrivate(t *testing.T) {
	j, sb := newJournal(t)
	if err := os.MkdirAll(j.Dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(j.LogPath(), []byte("an older line\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := j.Record(deletedResult(sb.Home("a"))); err != nil {
		t.Fatal(err)
	}
	sb.Advance(time.Minute)
	if err := j.Record(deletedResult(sb.Home("b"))); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(readText(t, j.LogPath()), "\n"), "\n")
	if len(lines) != 3 || lines[0] != "an older line" ||
		!strings.HasPrefix(lines[1], "2026-10-14 12:00:00 ") || !strings.HasPrefix(lines[2], "2026-10-14 12:01:00 ") {
		t.Errorf("records must be appended after what was there: %q", lines)
	}
	if st, _ := os.Stat(j.LogPath()); st.Mode().Perm() != 0o600 {
		t.Errorf("log mode = %v, want 0600", st.Mode().Perm())
	}
}

func TestFileJournal_CreatesItsFolderAndLogPrivately(t *testing.T) {
	j, sb := newJournal(t)
	if err := j.Record(deletedResult(sb.Home("a"))); err != nil {
		t.Fatal(err)
	}
	for path, want := range map[string]os.FileMode{j.Dir: 0o700, filepath.Dir(j.Dir): 0o700, j.LogPath(): 0o600} {
		st, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if st.Mode().Perm() != want {
			t.Errorf("%s: mode = %v, want %v", path, st.Mode().Perm(), want)
		}
	}
}

func TestFileJournal_QuotesLineSeparatorsAndBrokenText(t *testing.T) {
	for name, bad := range map[string]string{
		"line separator":      "a" + string(rune(0x2028)) + "b",
		"paragraph separator": "a" + string(rune(0x2029)) + "b",
		"invalid utf-8":       "a\xffb",
		"nul":                 "a\x00b",
	} {
		t.Run(name, func(t *testing.T) {
			j, sb := newJournal(t)
			if err := j.Record(deletedResult(sb.Home(bad))); err != nil {
				t.Fatal(err)
			}
			got := readText(t, j.LogPath())
			if strings.Contains(got, bad) || !strings.Contains(got, `deleted "`) {
				t.Errorf("a name with %s must be written quoted, not raw:\n%q", name, got)
			}
		})
	}
}

func TestFileJournal_ANameCannotForgeLogLines(t *testing.T) {
	j, sb := newJournal(t)
	evil := sb.Home("a\n2026-10-14 12:00:00 deleted /Users/saint/Documents")
	if err := j.Record(deletedResult(evil)); err != nil {
		t.Fatal(err)
	}
	failed := Result{Item: cand("r", "G", sb.Home("b"), 1), Status: StatusFailed, Reason: "boom\nsecond line\r"}
	if err := j.Record(failed); err != nil {
		t.Fatal(err)
	}
	got := readText(t, j.LogPath())
	if n := strings.Count(got, "\n"); n != 2 {
		t.Errorf("two records must be exactly two lines, got %d:\n%s", n, got)
	}
	if strings.Contains(got, "\r") || !strings.Contains(got, `\n`) {
		t.Errorf("control characters must be escaped, not written:\n%q", got)
	}
}

func TestFileJournal_NeverWritesThroughASymlinkedLog(t *testing.T) {
	j, sb := newJournal(t)
	target := sb.Home("elsewhere.txt")
	sb.WriteFile(t, target, 4, 0)
	if err := os.MkdirAll(j.Dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, j.LogPath()); err != nil {
		t.Fatal(err)
	}
	if err := j.Record(deletedResult(sb.Home("a"))); err == nil {
		t.Error("a log that is a symlink must be refused")
	}
	if got := readText(t, target); got != "xxxx" {
		t.Errorf("the link's target was written to: %q", got)
	}
}

func TestFileJournal_ReportsAStateFolderItCannotCreate(t *testing.T) {
	j, sb := newJournal(t)
	sb.WriteFile(t, j.Dir, 1, 0) // a file where the folder should be
	if err := j.Record(deletedResult(sb.Home("a"))); err == nil {
		t.Error("Record must report that it cannot write")
	}
	if err := j.Stamp(); err == nil {
		t.Error("Stamp must report that it cannot write")
	}
}

func TestFileJournal_WritesNothingOutsideATempDirWhileTesting(t *testing.T) {
	// A folder under /dev/null can never be created, so even if the safety net were broken this test could
	// not write anything real: it would see an error instead of the panic it expects.
	const notAHome = "/dev/null/not-a-test-home"
	j := NewFileJournal(notAHome, time.Now)
	for name, f := range map[string]func() error{
		"Record": func() error { return j.Record(deletedResult(notAHome + "/x")) },
		"Stamp":  j.Stamp,
	} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("%s outside a temp dir must panic while testing", name)
				}
			}()
			_ = f()
		}()
	}
}

// ---- the last-run stamp ----

func TestFileJournal_StampIsTheEpochSecondsOfTheRun(t *testing.T) {
	j, sb := newJournal(t)
	stamp := filepath.Join(j.Dir, "last-run")
	if err := j.Stamp(); err != nil {
		t.Fatalf("Stamp() failed: %v", err)
	}
	if got, want := readText(t, stamp), fmt.Sprintf("%d\n", sb.Env.Clock().Unix()); got != want {
		t.Errorf("stamp = %q, want %q", got, want)
	}
	if st, _ := os.Stat(stamp); st.Mode().Perm() != 0o600 {
		t.Errorf("stamp mode = %v, want 0600", st.Mode().Perm())
	}

	sb.Advance(48 * time.Hour)
	if err := j.Stamp(); err != nil {
		t.Fatal(err)
	}
	if got, want := readText(t, stamp), fmt.Sprintf("%d\n", sb.Env.Clock().Unix()); got != want {
		t.Errorf("a later run must replace the stamp: %q, want %q", got, want)
	}
	if entries, _ := os.ReadDir(j.Dir); len(entries) != 1 || entries[0].Name() != "last-run" {
		t.Errorf("no temporary files may be left behind: %v", entries)
	}
}

func TestFileJournal_AStampThatCannotBeWrittenLeavesNoTempFile(t *testing.T) {
	j, _ := newJournal(t)
	blocker := filepath.Join(j.Dir, "last-run")
	if err := os.MkdirAll(filepath.Join(blocker, "inside"), 0o700); err != nil { // a folder where the stamp should be
		t.Fatal(err)
	}
	if err := j.Stamp(); err == nil {
		t.Fatal("replacing a folder with a file must fail")
	}
	if entries, _ := os.ReadDir(j.Dir); len(entries) != 1 || entries[0].Name() != "last-run" {
		t.Errorf("a failed stamp must not leave its temporary file behind: %v", entries)
	}
}

func TestFileJournal_StampReplacesALinkInsteadOfWritingThroughIt(t *testing.T) {
	j, sb := newJournal(t)
	target := sb.Home("elsewhere.txt")
	sb.WriteFile(t, target, 4, 0)
	if err := os.MkdirAll(j.Dir, 0o700); err != nil {
		t.Fatal(err)
	}
	stamp := filepath.Join(j.Dir, "last-run")
	if err := os.Symlink(target, stamp); err != nil {
		t.Fatal(err)
	}
	if err := j.Stamp(); err != nil {
		t.Fatalf("Stamp() failed: %v", err)
	}
	if got := readText(t, target); got != "xxxx" {
		t.Errorf("the link's target was written to: %q", got)
	}
	if st, err := os.Lstat(stamp); err != nil || st.Mode()&os.ModeSymlink != 0 {
		t.Errorf("the stamp must now be a regular file: %v %v", st, err)
	}
}

func TestLastRun_ReadsOnlyAWellFormedStamp(t *testing.T) {
	cases := []struct {
		name, content string
		ok            bool
	}{
		{"epoch with newline", "1791979200\n", true},
		{"epoch without newline", "1791979200", true},
		{"padding and CRLF", "  1791979200 \r\n", true},
		{"empty", "", false},
		{"text", "yesterday\n", false},
		{"negative", "-5\n", false},
		{"zero", "0\n", false},
		{"plus sign", "+1791979200\n", false},
		{"two numbers", "1791979200 1791979201\n", false},
		{"float", "1.7e9\n", false},
		{"overflow", "99999999999999999999999\n", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			sb := systest.NewSandbox(t)
			if err := os.MkdirAll(StateDir(sb.Env.Home), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(StateDir(sb.Env.Home), "last-run"), []byte(c.content), 0o600); err != nil {
				t.Fatal(err)
			}
			got, ok := LastRun(sb.Env.Home)
			if ok != c.ok || (ok && !got.Equal(time.Unix(1791979200, 0))) {
				t.Errorf("LastRun = %v, %v; want ok=%v", got, ok, c.ok)
			}
		})
	}
}

func TestLastRun_MissingOrNotAFile(t *testing.T) {
	sb := systest.NewSandbox(t)
	if _, ok := LastRun(sb.Env.Home); ok {
		t.Error("no stamp, no answer")
	}
	if err := os.MkdirAll(filepath.Join(StateDir(sb.Env.Home), "last-run"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, ok := LastRun(sb.Env.Home); ok {
		t.Error("a folder is not a stamp")
	}
}

// ---- Apply and the journal ----

type fakeJournal struct {
	records             []Result
	goneAtRecord        []bool // for deleted files: was the path already gone when Record ran?
	stamps              int
	recordErr, stampErr error
}

func (j *fakeJournal) Record(r Result) error {
	j.records = append(j.records, r)
	if r.Status == StatusDeleted && r.Item.Action == rules.ActionDelete {
		j.goneAtRecord = append(j.goneAtRecord, !exists(r.Item.Path))
	}
	return j.recordErr
}

func (j *fakeJournal) Stamp() error { j.stamps++; return j.stampErr }

func TestApply_JournalSeesEachDeletionOnlyAfterTheItemIsGone(t *testing.T) {
	f, _, a, b := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)
	j := &fakeJournal{}
	f.eng.Journal = j

	if _, err := f.eng.Apply(ctx, plan, ApplyOptions{}); err != nil {
		t.Fatal(err)
	}
	if len(j.records) != 2 || j.records[0].Item.Path != a || j.records[1].Item.Path != b {
		t.Fatalf("both deletions must be recorded in plan order: %+v", j.records)
	}
	for i, gone := range j.goneAtRecord {
		if !gone {
			t.Errorf("record %d was written before the item was gone", i)
		}
	}
	if j.stamps != 1 {
		t.Errorf("a run that cleaned something stamps once, got %d", j.stamps)
	}
}

func threeItems(t *testing.T) (f *fixture, fail, skip, ok string) {
	t.Helper()
	f = newFixture(t)
	fail = filepath.Dir(f.laneFile(t, "a", "node_modules/x", 10))
	skip = filepath.Dir(f.laneFile(t, "b", "node_modules/y", 10))
	ok = filepath.Dir(f.laneFile(t, "c", "node_modules/z", 10))
	f.eng.Rules = []rules.Rule{&fakeRule{id: "deps", group: "Deps",
		items:      []rules.Candidate{cand("", "Deps", fail, 1), cand("", "Deps", skip, 2), cand("", "Deps", ok, 4)},
		recheckErr: map[string]error{skip: errors.New("in use now")}}}
	f.eng.Remove = func(p string) error {
		if p == fail {
			return errors.New("permission denied")
		}
		return os.RemoveAll(p)
	}
	return f, fail, skip, ok
}

func TestApply_JournalSeesDeletionsAndFailuresButNotSkips(t *testing.T) {
	f, fail, _, ok := threeItems(t)
	plan, _ := f.eng.Plan(ctx)
	j := &fakeJournal{}
	f.eng.Journal = j

	rep, err := f.eng.Apply(ctx, plan, ApplyOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if rep.Deleted != 1 || rep.Failed != 1 || rep.Skipped != 1 {
		t.Fatalf("unexpected report: %+v", rep)
	}
	if len(j.records) != 2 || j.records[0].Item.Path != fail || j.records[0].Status != StatusFailed ||
		j.records[1].Item.Path != ok || j.records[1].Status != StatusDeleted {
		t.Errorf("only the failure and the deletion are recorded: %+v", j.records)
	}
	if j.stamps != 1 {
		t.Errorf("one item was cleaned, so the run is stamped once, got %d", j.stamps)
	}
}

func TestApply_NothingCleanedMeansNoStamp(t *testing.T) {
	f, fail, _, _ := threeItems(t)
	plan, _ := f.eng.Plan(ctx)
	plan.Items = plan.Items[:2] // the item that fails and the item that is skipped; the one that works is left out
	j := &fakeJournal{}
	f.eng.Journal = j

	rep, err := f.eng.Apply(ctx, plan, ApplyOptions{})
	if err != nil || rep.Deleted != 0 || rep.Failed != 1 || rep.Skipped != 1 {
		t.Fatalf("setup: want one failure, one skip and nothing deleted: err=%v %+v", err, rep)
	}
	if j.stamps != 0 {
		t.Errorf("a run that cleaned nothing must not stamp, got %d", j.stamps)
	}
	if len(j.records) != 1 || j.records[0].Status != StatusFailed || j.records[0].Item.Path != fail {
		t.Errorf("the failure is still recorded: %+v", j.records)
	}
}

func TestApply_DryRunNeverTouchesTheJournal(t *testing.T) {
	f, _, a, b := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)
	j := &fakeJournal{}
	f.eng.Journal = j

	if _, err := f.eng.Apply(ctx, plan, ApplyOptions{DryRun: true}); err != nil {
		t.Fatal(err)
	}
	if len(j.records) != 0 || j.stamps != 0 {
		t.Errorf("a dry run must write nothing: %+v stamps=%d", j.records, j.stamps)
	}
	if !exists(a) || !exists(b) {
		t.Error("a dry run deleted something")
	}
}

func TestApply_ADryRunNeverJournalsEvenAFailure(t *testing.T) {
	f, _, a, _ := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)
	plan.Items = append(plan.Items, cand("no-such-rule", "X", a, 1)) // fails even in a dry run
	j := &fakeJournal{}
	f.eng.Journal = j

	rep, _ := f.eng.Apply(ctx, plan, ApplyOptions{DryRun: true})
	if rep.Failed != 1 {
		t.Fatalf("setup: the unknown rule should fail: %+v", rep)
	}
	if len(j.records) != 0 || j.stamps != 0 {
		t.Errorf("a dry run writes nothing, not even a failure: %+v stamps=%d", j.records, j.stamps)
	}
}

func TestApply_AJournalThatFailsNeverStopsADeletion(t *testing.T) {
	f, _, a, b := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)
	f.eng.Journal = &fakeJournal{recordErr: errors.New("disk full"), stampErr: errors.New("read-only volume")}

	rep, err := f.eng.Apply(ctx, plan, ApplyOptions{})
	if err != nil {
		t.Fatalf("a journal problem is not a failure of the run: %v", err)
	}
	if exists(a) || exists(b) || rep.Deleted != 2 || !rep.OK() {
		t.Errorf("both items must still be deleted: %+v", rep)
	}
	if len(rep.Warnings) != 2 ||
		!strings.Contains(rep.Warnings[0], "cleanup log") || !strings.Contains(rep.Warnings[0], "disk full") ||
		!strings.Contains(rep.Warnings[1], "last-run stamp") || !strings.Contains(rep.Warnings[1], "read-only volume") {
		t.Errorf("each journal problem is reported once, even if it repeats: %q", rep.Warnings)
	}
}

func TestApply_StampedEvenIfCutShortAfterSomethingWasCleaned(t *testing.T) {
	f, _, a, b := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)
	j := &fakeJournal{}
	f.eng.Journal = j
	cctx, cancel := context.WithCancel(ctx)
	f.eng.Remove = func(path string) error {
		err := os.RemoveAll(path)
		cancel()
		return err
	}

	rep, err := f.eng.Apply(cctx, plan, ApplyOptions{})
	if !errors.Is(err, context.Canceled) || rep.Deleted != 1 || exists(a) || !exists(b) {
		t.Fatalf("setup: want one item done and the run cut short: err=%v %+v", err, rep)
	}
	if len(j.records) != 1 || j.stamps != 1 {
		t.Errorf("what was done is recorded and stamped: %+v stamps=%d", j.records, j.stamps)
	}
}

func TestApply_WithoutAJournalWorksAsBefore(t *testing.T) {
	f, _, a, b := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)
	rep, err := f.eng.Apply(ctx, plan, ApplyOptions{})
	if err != nil || exists(a) || exists(b) || len(rep.Warnings) != 0 {
		t.Errorf("err=%v warnings=%v", err, rep.Warnings)
	}
}
