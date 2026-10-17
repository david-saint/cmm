package ui

import (
	"errors"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/david-saint/cmm/pkg/cmm"
)

type mockModule struct {
	name string
}

func (m mockModule) Name() string                                    { return m.name }
func (m mockModule) Description() string                             { return "desc" }
func (m mockModule) Category() string                                { return "Recommended" }
func (m mockModule) Scan() ([]cmm.FileItem, error)                   { return nil, nil }
func (m mockModule) Delete([]cmm.FileItem) (cmm.DeleteResult, error) { return cmm.DeleteResult{}, nil }

// recordingModule remembers what it was asked to delete and answers with a prepared result.
type recordingModule struct {
	name  string
	res   cmm.DeleteResult
	calls *[][]cmm.FileItem
}

func (m recordingModule) Name() string                  { return m.name }
func (m recordingModule) Description() string           { return "desc" }
func (m recordingModule) Category() string              { return "Recommended" }
func (m recordingModule) Scan() ([]cmm.FileItem, error) { return nil, nil }
func (m recordingModule) Delete(items []cmm.FileItem) (cmm.DeleteResult, error) {
	*m.calls = append(*m.calls, items)
	return m.res, nil
}

var (
	enterKey = tea.KeyMsg{Type: tea.KeyEnter}
	yKey     = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}}
	nKey     = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'n'}}
)

func TestInitialModel(t *testing.T) {
	modules := []cmm.Module{
		mockModule{name: "Module 1"},
		mockModule{name: "Module 2"},
	}
	m := NewModel(nil, modules, Config{})

	if len(m.choices) != 2 {
		t.Errorf("expected 2 choices, got %d", len(m.choices))
	}

	if m.cursor != 0 {
		t.Errorf("expected cursor at 0, got %d", m.cursor)
	}
}

func TestModel_Update(t *testing.T) {
	modules := []cmm.Module{
		mockModule{name: "Module 1"},
		mockModule{name: "Module 2"},
	}
	m := NewModel(nil, modules, Config{})

	// Test cursor movement
	msg := tea.KeyMsg{Type: tea.KeyDown}
	newModel, _ := m.Update(msg)
	m = newModel.(Model)

	if m.cursor != 1 {
		t.Errorf("expected cursor at 1 after KeyDown, got %d", m.cursor)
	}

	msg = tea.KeyMsg{Type: tea.KeyUp}
	newModel, _ = m.Update(msg)
	m = newModel.(Model)

	if m.cursor != 0 {
		t.Errorf("expected cursor at 0 after KeyUp, got %d", m.cursor)
	}

	// Test selection
	msg = tea.KeyMsg{Type: tea.KeySpace}
	newModel, _ = m.Update(msg)
	m = newModel.(Model)

	if _, ok := m.selected[0]; !ok {
		t.Errorf("expected item 0 to be selected after space")
	}

	newModel, _ = m.Update(msg)
	m = newModel.(Model)

	if _, ok := m.selected[0]; ok {
		t.Errorf("expected item 0 to be deselected after second space")
	}
}

func TestModel_EscNavigation(t *testing.T) {
	modules := []cmm.Module{
		mockModule{name: "Module 1"},
	}
	m := NewModel(nil, modules, Config{})
	msg := tea.KeyMsg{Type: tea.KeyEsc}

	// From stateResults to stateSelecting
	m.state = stateResults
	newModel, _ := m.Update(msg)
	m = newModel.(Model)
	if m.state != stateSelecting {
		t.Errorf("expected stateSelecting after Esc from stateResults, got %v", m.state)
	}

	// From stateConfirming to stateResults
	m.state = stateConfirming
	newModel, _ = m.Update(msg)
	m = newModel.(Model)
	if m.state != stateResults {
		t.Errorf("expected stateResults after Esc from stateConfirming, got %v", m.state)
	}

	// From stateScanning to stateSelecting
	m.state = stateScanning
	newModel, _ = m.Update(msg)
	m = newModel.(Model)
	if m.state != stateSelecting {
		t.Errorf("expected stateSelecting after Esc from stateScanning, got %v", m.state)
	}
}

func TestModel_ToggleExpanded(t *testing.T) {
	modules := []cmm.Module{
		mockModule{name: "Module 1"},
	}
	m := NewModel(nil, modules, Config{})
	m.state = stateResults
	m.results = []cmm.ModuleResult{
		{Module: modules[0], Items: []cmm.FileItem{{Path: "p1", Size: 10}}},
	}

	// Toggle on space
	msg := tea.KeyMsg{Type: tea.KeySpace}
	newModel, _ := m.Update(msg)
	m = newModel.(Model)
	if !m.expanded[0] {
		t.Errorf("expected module 0 to be expanded after space")
	}

	// Toggle off space
	newModel, _ = m.Update(msg)
	m = newModel.(Model)
	if m.expanded[0] {
		t.Errorf("expected module 0 to be collapsed after second space")
	}
}

// ---- preview-only: nothing can be deleted ----

func TestView_PreviewBannerSaysNothingWillBeDeleted(t *testing.T) {
	mods := []cmm.Module{mockModule{name: "Module 1"}}
	preview := NewModel(nil, mods, Config{DryRun: true}).View()
	for _, want := range []string{"PREVIEW ONLY", "nothing will be deleted", "--apply"} {
		if !strings.Contains(preview, want) {
			t.Errorf("the preview screen should say %q:\n%s", want, preview)
		}
	}
	if real := NewModel(nil, mods, Config{}).View(); strings.Contains(real, "PREVIEW") {
		t.Errorf("a real run must not claim to be a preview:\n%s", real)
	}
}

func TestModel_PreviewNeverAsksToConfirm(t *testing.T) {
	m := NewModel(nil, []cmm.Module{mockModule{name: "Module 1"}}, Config{DryRun: true})
	m.state = stateResults

	next, cmd := m.Update(enterKey)
	if next.(Model).state == stateConfirming || next.(Model).state == stateExecuting {
		t.Fatalf("a preview must never reach the confirmation, state = %v", next.(Model).state)
	}
	if cmd == nil {
		t.Fatal("Return should end the preview")
	}
	if _, quit := cmd().(tea.QuitMsg); !quit {
		t.Error("Return should quit the preview")
	}
}

func TestExecute_APreviewNeverReachesAModule(t *testing.T) {
	var calls [][]cmm.FileItem
	mod := recordingModule{name: "A", calls: &calls}
	m := NewModel(nil, []cmm.Module{mod}, Config{DryRun: true})
	m.results = []cmm.ModuleResult{{Module: mod, Items: []cmm.FileItem{{Path: "p", Size: 1}}}}

	msg := m.runExecute()
	if got, ok := msg.(executeMsg); !ok || len(got) != 0 {
		t.Errorf("a preview executes nothing and reports nothing: %#v", msg)
	}
	if len(calls) != 0 {
		t.Error("even if the screen is bypassed, a preview must not call Delete")
	}
}

// ---- the confirmation ----

func TestModel_OnlyYConfirmsADeletion(t *testing.T) {
	var calls [][]cmm.FileItem
	mod := recordingModule{name: "A", calls: &calls}
	m := NewModel(nil, []cmm.Module{mod}, Config{})
	m.results = []cmm.ModuleResult{{Module: mod, Items: []cmm.FileItem{{Path: "p", Size: 1}}}}
	m.state = stateResults

	next, cmd := m.Update(enterKey) // from the results to the question
	m = next.(Model)
	if m.state != stateConfirming || cmd != nil {
		t.Fatalf("Return on the results asks the question and deletes nothing: state=%v", m.state)
	}

	// Return, and anything else but y, must not answer the question: holding Return down must never delete
	for _, k := range []tea.Msg{enterKey, tea.KeyMsg{Type: tea.KeySpace}, tea.KeyMsg{Type: tea.KeyDown}, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'x'}}} {
		next, cmd = m.Update(k)
		m = next.(Model)
		if m.state != stateConfirming || cmd != nil {
			t.Fatalf("key %v answered the question: state=%v", k, m.state)
		}
	}
	if len(calls) != 0 {
		t.Fatal("nothing may be deleted before y")
	}

	next, cmd = m.Update(yKey)
	m = next.(Model)
	if m.state != stateExecuting || cmd == nil {
		t.Fatalf("y confirms: state=%v", m.state)
	}
	if _, ok := cmd().(executeMsg); !ok || len(calls) != 1 {
		t.Errorf("y should run the deletion once: calls=%d", len(calls))
	}
}

func TestModel_NGoesBackWithoutDeleting(t *testing.T) {
	var calls [][]cmm.FileItem
	mod := recordingModule{name: "A", calls: &calls}
	m := NewModel(nil, []cmm.Module{mod}, Config{})
	m.results = []cmm.ModuleResult{{Module: mod, Items: []cmm.FileItem{{Path: "p", Size: 1}}}}
	m.state = stateConfirming

	next, cmd := m.Update(nKey)
	if next.(Model).state != stateResults || cmd != nil || len(calls) != 0 {
		t.Errorf("n cancels: state=%v calls=%d", next.(Model).state, len(calls))
	}
}

// ---- the finished screen tells what really happened ----

func TestFinished_ReportsWhatReallyHappened(t *testing.T) {
	a, b, c := mockModule{name: "Alpha"}, mockModule{name: "Beta"}, mockModule{name: "Gamma"}
	m := NewModel(nil, []cmm.Module{a, b, c}, Config{})
	m.results = []cmm.ModuleResult{
		{Module: a, Items: []cmm.FileItem{{Path: "a1", Size: 2048}, {Path: "a2", Size: 1024}}},
		{Module: b, Items: []cmm.FileItem{{Path: "b1", Size: 5120}}},
		{Module: c, Items: []cmm.FileItem{{Path: "c1", Size: 100}}},
	}
	outcomes := []cmm.Outcome{
		{Module: a, Result: cmm.DeleteResult{Freed: 1024, Skipped: 1, Failed: 1,
			Notes: []string{"skipped: a1: in use now", "FAILED: a2: permission denied"}}},
		{Module: b, Result: cmm.DeleteResult{Freed: 5120}},
		{Module: c, Err: errors.New("tmutil is not available")},
	}

	next, _ := m.Update(executeMsg(outcomes))
	view := next.(Model).View()
	for _, want := range []string{
		"Alpha: freed 1.0 KB of 3.0 KB, 1 skipped, 1 failed",
		"skipped: a1: in use now",
		"FAILED: a2: permission denied",
		"Beta: freed 5.0 KB of 5.0 KB",
		"Gamma: FAILED: tmutil is not available",
		"Reclaimed 6.0 KB in total",
		"with problems",
	} {
		if !strings.Contains(view, want) {
			t.Errorf("the finished screen should contain %q:\n%s", want, view)
		}
	}
	if strings.Contains(view, "8.1 KB") {
		t.Errorf("the planned total must never be presented as what was freed:\n%s", view)
	}
}

func TestFinished_ACleanRunSaysSo(t *testing.T) {
	a := mockModule{name: "Alpha"}
	m := NewModel(nil, []cmm.Module{a}, Config{})
	m.results = []cmm.ModuleResult{{Module: a, Items: []cmm.FileItem{{Path: "a1", Size: 2048}}}}

	next, _ := m.Update(executeMsg([]cmm.Outcome{{Module: a, Result: cmm.DeleteResult{Freed: 2048}}}))
	view := next.(Model).View()
	if !strings.Contains(view, "Cleanup Complete!") || strings.Contains(view, "problems") || !strings.Contains(view, "Alpha: freed 2.0 KB of 2.0 KB") {
		t.Errorf("a clean run is reported plainly:\n%s", view)
	}
}

func TestFinished_LongNoteListsAreCut(t *testing.T) {
	a := mockModule{name: "Alpha"}
	m := NewModel(nil, []cmm.Module{a}, Config{})
	m.results = []cmm.ModuleResult{{Module: a, Items: []cmm.FileItem{{Path: "a1", Size: 1}}}}
	var notes []string
	for i := range 9 {
		notes = append(notes, "FAILED: item"+string(rune('A'+i))+": no")
	}

	next, _ := m.Update(executeMsg([]cmm.Outcome{{Module: a, Result: cmm.DeleteResult{Failed: 9, Notes: notes}}}))
	view := next.(Model).View()
	if !strings.Contains(view, "itemE") || strings.Contains(view, "itemF") || !strings.Contains(view, "and 4 more") {
		t.Errorf("five notes are shown, the rest are counted:\n%s", view)
	}
}

func TestExecute_EachModuleGetsItsOwnItemsAndTheOutcomesComeBack(t *testing.T) {
	var callsA, callsB [][]cmm.FileItem
	a := recordingModule{name: "A", res: cmm.DeleteResult{Freed: 10}, calls: &callsA}
	b := recordingModule{name: "B", res: cmm.DeleteResult{Freed: 20, Skipped: 1}, calls: &callsB}
	m := NewModel(nil, []cmm.Module{a, b}, Config{})
	m.results = []cmm.ModuleResult{
		{Module: a, Items: []cmm.FileItem{{Path: "a1", Size: 10}}},
		{Module: b, Items: []cmm.FileItem{{Path: "b1", Size: 30}}},
	}

	got, ok := m.runExecute().(executeMsg)
	if !ok || len(got) != 2 || got[0].Result.Freed != 10 || got[1].Result.Skipped != 1 {
		t.Fatalf("outcomes = %#v", got)
	}
	if len(callsA) != 1 || callsA[0][0].Path != "a1" || len(callsB) != 1 || callsB[0][0].Path != "b1" {
		t.Errorf("each module deletes only its own items: %v %v", callsA, callsB)
	}
}

func TestFinished_SkippedOrFailedItemsAreProblemsEvenWithoutAnError(t *testing.T) {
	a := mockModule{name: "Alpha"}
	for name, res := range map[string]cmm.DeleteResult{
		"skipped": {Skipped: 1, Notes: []string{"skipped: x"}},
		"failed":  {Failed: 1, Notes: []string{"FAILED: x"}},
	} {
		m := NewModel(nil, []cmm.Module{a}, Config{})
		m.results = []cmm.ModuleResult{{Module: a, Items: []cmm.FileItem{{Path: "x", Size: 1}}}}
		next, _ := m.Update(executeMsg([]cmm.Outcome{{Module: a, Result: res}}))
		if view := next.(Model).View(); !strings.Contains(view, "with problems") || strings.Contains(view, "Cleanup Complete!") {
			t.Errorf("%s: a run that left items behind must not look complete:\n%s", name, view)
		}
	}
}
