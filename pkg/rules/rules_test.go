package rules

import "testing"

func TestTierValid(t *testing.T) {
	for _, ok := range []Tier{TierSafe, TierReview, TierManual} {
		if !ok.Valid() {
			t.Errorf("%q should be valid", ok)
		}
	}
	for _, bad := range []Tier{"", "yolo", "SAFE"} {
		if bad.Valid() {
			t.Errorf("%q should be invalid", bad)
		}
	}
}

func TestActionValid(t *testing.T) {
	for _, ok := range []Action{ActionDelete, ActionCommand} {
		if !ok.Valid() {
			t.Errorf("%q should be valid", ok)
		}
	}
	for _, bad := range []Action{"", "rm", "DELETE"} {
		if bad.Valid() {
			t.Errorf("%q should be invalid", bad)
		}
	}
}
