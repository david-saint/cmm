package rules

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/david-saint/cmm/pkg/guard"
	"github.com/david-saint/cmm/pkg/policy"
	"github.com/david-saint/cmm/pkg/sizer"
)

var (
	// udidRE is the exact form of a simulator device id as simctl prints it.
	udidRE = regexp.MustCompile(`^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$`)
	// udidFindRE finds device ids inside longer lines of simctl output.
	udidFindRE = regexp.MustCompile(`[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}`)
)

const (
	// runtimeMarker appears in every runtime simctl lists; a list without it means CoreSimulator is not
	// answering normally and nothing may be concluded from it.
	runtimeMarker = "com.apple.CoreSimulator.SimRuntime"
	runtimePrefix = runtimeMarker + "."
	// simShutdown is the state device.plist records for a device that is shut down.
	simShutdown   = "1"
	simctlTimeout = 90 * time.Second
)

// SimulatorsRule deletes simulator devices whose runtime has been removed (simctl calls them unavailable).
// Such a device can never be started again. It is deleted through `simctl delete`, not by removing its
// folder, so CoreSimulator's own bookkeeping stays right.
//
// A device is left alone, with a reason, when its runtime is recorded nowhere or is installed after all, when it
// is not shut down, when its folder or anything directly in it changed within Settle, when something has it
// open, or when simctl does not list it as unavailable. If CoreSimulator does not answer at all, no device is
// judged.
type SimulatorsRule struct {
	RuleID  string
	Label   string
	Devices string        // "~/Library/Developer/CoreSimulator/Devices"
	Settle  time.Duration // a device changed this recently is left alone
	Tier    Tier          // empty means TierSafe
}

// ID implements Rule.
func (r *SimulatorsRule) ID() string { return r.RuleID }

// Group implements Rule.
func (r *SimulatorsRule) Group() string { return r.Label }

func (r *SimulatorsRule) tier() Tier {
	if r.Tier == "" {
		return TierSafe
	}
	return r.Tier
}

func regularFile(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular()
}

// simctl runs `xcrun simctl <args>` and returns its output. Any failure to answer is an error.
func (r *SimulatorsRule) simctl(ctx context.Context, d Deps, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, simctlTimeout)
	defer cancel()
	res, err := d.Env.Runner.Run(ctx, "xcrun", append([]string{"simctl"}, args...)...)
	if err != nil {
		return "", err
	}
	if res.ExitCode != 0 {
		msg := strings.TrimSpace(res.Stderr)
		if len(msg) > 300 {
			msg = msg[:300]
		}
		return "", fmt.Errorf("simctl %s exited with status %d: %s", strings.Join(args, " "), res.ExitCode, msg)
	}
	return res.Stdout, nil
}

// runtimes lists the installed runtimes. A list without a single runtime in it is an error: it means
// CoreSimulator is not answering normally, and then no device may be called unavailable.
func (r *SimulatorsRule) runtimes(ctx context.Context, d Deps) (string, error) {
	out, err := r.simctl(ctx, d, "list", "runtimes")
	if err != nil {
		return "", err
	}
	if !strings.Contains(out, runtimeMarker) {
		return "", errors.New("the list has no runtime in it")
	}
	return out, nil
}

// unavailable returns the ids of the devices simctl calls unavailable, each once, in the order listed.
func (r *SimulatorsRule) unavailable(ctx context.Context, d Deps) ([]string, error) {
	out, err := r.simctl(ctx, d, "list", "devices", "unavailable")
	if err != nil {
		return nil, err
	}
	var ids []string
	for _, id := range udidFindRE.FindAllString(out, -1) {
		if !slices.Contains(ids, id) {
			ids = append(ids, id)
		}
	}
	return ids, nil
}

// plistValue reads one key of a device.plist; any failure gives "", which no guard accepts.
func plistValue(ctx context.Context, d Deps, plist, key string) string {
	res, err := d.Env.Runner.Run(ctx, "plutil", "-extract", key, "raw", plist)
	if err != nil || res.ExitCode != 0 {
		return ""
	}
	return strings.TrimSpace(res.Stdout)
}

// judge applies every guard to one device that simctl lists as unavailable. It returns a label for the device
// and, when the device must stay, the reason in words.
func (r *SimulatorsRule) judge(ctx context.Context, d Deps, udid, dir, runtimes string) (label, reason string) {
	plist := filepath.Join(dir, "device.plist")
	rt := plistValue(ctx, d, plist, "runtime")
	state := plistValue(ctx, d, plist, "state")
	name := plistValue(ctx, d, plist, "name")
	if name == "" {
		name = udid
	}
	label = fmt.Sprintf("%s (%s)", name, strings.TrimPrefix(rt, runtimePrefix))
	stay := func(format string, args ...any) (string, string) {
		return label, fmt.Sprintf("simulator %s: %s", label, fmt.Sprintf(format, args...))
	}

	if rt == "" {
		return "", fmt.Sprintf("simulator %s: no runtime recorded", udid)
	}
	if state != simShutdown {
		return stay("not shut down")
	}
	if strings.Contains(runtimes, rt) {
		return stay("its runtime is installed after all")
	}
	recent, err := d.Guard.RecentlyModified(dir, guard.Recent{Within: r.Settle, MaxDepth: 1})
	if err != nil {
		return stay("could not check when it was last used (%v)", err)
	}
	if recent {
		return stay("changed in the last %d days", int(r.Settle/(24*time.Hour)))
	}
	inUse, err := d.Guard.InUse(ctx, dir)
	if err != nil {
		return stay("could not check whether it is in use (%v)", err)
	}
	if inUse {
		return stay("something has it open")
	}
	return label, ""
}

// Plan implements Rule.
func (r *SimulatorsRule) Plan(ctx context.Context, d Deps) ([]Candidate, []Skip, error) {
	root, ok := expandRoot(d, r.Devices)
	if !ok {
		return nil, nil, nil
	}
	if _, err := os.Lstat(root); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil, nil
		}
		return nil, []Skip{{Reason: fmt.Sprintf("%s: cannot read %s (%v)", r.Label, root, err)}}, nil
	}
	if err := d.Policy.CheckNoSymlinks(root); err != nil {
		return nil, []Skip{{Reason: fmt.Sprintf("%s: %v", r.Label, err)}}, nil
	}

	runtimes, err := r.runtimes(ctx, d)
	if err != nil {
		return nil, []Skip{{Reason: fmt.Sprintf("simulators: CoreSimulator did not list any runtime, so no device was judged unavailable (%v)", err)}}, nil
	}
	ids, err := r.unavailable(ctx, d)
	if err != nil {
		return nil, []Skip{{Reason: fmt.Sprintf("simulators: could not list the unavailable devices (%v)", err)}}, nil
	}

	var items []Candidate
	var skips []Skip
	for _, udid := range ids {
		dir := filepath.Join(root, udid)
		if !regularFile(filepath.Join(dir, "device.plist")) {
			continue // listed, but not a device folder on this disk
		}
		if err := d.Policy.CheckNoSymlinks(dir); err != nil {
			skips = append(skips, Skip{Reason: fmt.Sprintf("simulator %s: %v", udid, err)})
			continue
		}
		label, reason := r.judge(ctx, d, udid, dir, runtimes)
		if reason != "" {
			skips = append(skips, Skip{Reason: reason})
			continue
		}
		res, err := sizer.Measure(dir)
		if err != nil {
			skips = append(skips, Skip{Reason: fmt.Sprintf("simulator %s: could not measure (%v)", label, err)})
			continue
		}
		c := Candidate{
			Rule: r.RuleID, Group: r.Label, Path: dir, Bytes: res.Bytes, Tier: r.tier(), Action: ActionCommand,
			Note: label + ": its runtime is no longer installed",
		}
		if res.Unreadable > 0 {
			c.Note += fmt.Sprintf("; %d entries could not be read, so the size is a lower bound", res.Unreadable)
		}
		items = append(items, c)
	}
	return items, skips, nil
}

// locate returns the device id of a path this rule may claim: a direct child of Devices named like a device id.
func (r *SimulatorsRule) locate(d Deps, p string) (string, bool) {
	root, ok := expandRoot(d, r.Devices)
	if !ok || p == "" || filepath.Clean(p) != p || !policy.ChildOf(p, root) {
		return "", false
	}
	udid := filepath.Base(p)
	return udid, udidRE.MatchString(udid)
}

// Allows implements Rule: only a folder directly in Devices that is named like a device id.
func (r *SimulatorsRule) Allows(d Deps, p string) bool {
	_, ok := r.locate(d, p)
	return ok
}

// Recheck implements Rule: simctl is asked again, so a runtime that was installed after planning, or a device
// that became available, is noticed, and so is every other guard.
func (r *SimulatorsRule) Recheck(ctx context.Context, d Deps, c Candidate) error {
	udid, ok := r.locate(d, c.Path)
	if !ok {
		return fmt.Errorf("%s: %q is not a simulator device folder", r.Label, c.Path)
	}
	if !regularFile(filepath.Join(c.Path, "device.plist")) {
		return fmt.Errorf("simulator %s: device.plist is gone", udid)
	}
	runtimes, err := r.runtimes(ctx, d)
	if err != nil {
		return fmt.Errorf("simulators: CoreSimulator did not list any runtime, so the device was not judged unavailable (%v)", err)
	}
	ids, err := r.unavailable(ctx, d)
	if err != nil {
		return fmt.Errorf("simulators: could not list the unavailable devices (%v)", err)
	}
	if !slices.Contains(ids, udid) {
		return fmt.Errorf("simulator %s: no longer unavailable", udid)
	}
	if _, reason := r.judge(ctx, d, udid, c.Path, runtimes); reason != "" {
		return errors.New(reason)
	}
	return nil
}

// Execute implements Executor: `simctl delete <id>`, then a check that the device folder is really gone.
func (r *SimulatorsRule) Execute(ctx context.Context, d Deps, c Candidate) (int64, error) {
	udid, ok := r.locate(d, c.Path)
	if !ok {
		return 0, fmt.Errorf("%s: %q is not a simulator device folder", r.Label, c.Path)
	}
	if !regularFile(filepath.Join(c.Path, "device.plist")) {
		return 0, fmt.Errorf("simulator %s: device.plist is gone", udid)
	}
	if _, err := r.simctl(ctx, d, "delete", udid); err != nil {
		return 0, fmt.Errorf("simulator %s: %v", udid, err)
	}
	if _, err := os.Lstat(c.Path); !errors.Is(err, fs.ErrNotExist) {
		return 0, fmt.Errorf("simulator %s: simctl delete finished but the device folder is still there", udid)
	}
	return c.Bytes, nil
}
