// Package fluxcontract holds contract tests for upstream Flux types this
// repository reads through kubectl rather than through the Go API.
//
// A shell script that pulls a field out of a Kubernetes object with
// `kubectl -o jsonpath` depends on the serialized shape of an upstream Go
// struct, and nothing in the shell layer can observe that dependency. Rename
// the field upstream and the expression stops matching: kubectl prints
// nothing, exits zero, and the caller reads the empty output as an answer
// about the object rather than as a question that no longer parses.
//
// The test for that cannot live in the shell layer either. Pointing an
// expression at a document written by the same test proves the reader can read
// that document and nothing else, because a rename moves neither side.
//
// So this file supplies neither half. The expression comes from the shell
// library that ships it, obtained by sourcing that library, and the object is
// built from the upstream type at the version go.mod pins. What is left to
// assert is that the one still finds the other.
//
// One test does that. The other two exist because the expression reaches
// kubectl through a shell variable that the caller expands, and both steps of
// that indirection can fail without saying so.
package fluxcontract

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	helmv2 "github.com/fluxcd/helm-controller/api/v2"
	"k8s.io/client-go/util/jsonpath"
)

const (
	// The shell library that owns the expression, and the script that runs it.
	guardLibrary = "../../hack/e2e-chainsaw/_lib/remediation-guard.sh"
	guardCaller  = "../../hack/e2e-chainsaw/_lib/run-kubernetes.sh"

	sharedName = "HELMRELEASE_HISTORY_JSONPATH"
)

// The name followed by an `=`, wherever it appears and however indented. Named
// after what it matches rather than what it is used to find: an occurrence is
// not an assignment, a comment mentioning one counts, and a message built on
// this has to say occurrence or it claims more than the pattern saw.
var nameFollowedByEquals = regexp.MustCompile(`HELMRELEASE_HISTORY_JSONPATH=`)

// The caller's read: a line-starting assignment taking its value from a
// kubectl call that passes the expansion of the shared name as its jsonpath.
//
// The `$` is load-bearing rather than decorative. Matching the bare name would
// accept `jsonpath=HELMRELEASE_HISTORY_JSONPATH`, which kubectl reads as a
// template with no braces and echoes back verbatim. That output is not empty,
// so the script's own empty-history backstop stays quiet while carrying no
// status the cycle check can match, which is this file's whole subject
// arriving with the pin green over it.
//
// The local's name, the spelling of `-o`, and the quoting of the substitution
// are left free, because this script mixes forms that behave identically and a
// pin on those reddens for a rewrite that changed nothing. Each of those is a
// case in the accept table below, so that "free" is enforced rather than
// announced; a spelling absent from that table is one nobody checked, not one
// known to be rejected.
//
// A form this pattern does not cover reddens rather than passing: the caller
// test fails with the pattern printed. So the list is a record of what was
// checked and not a contract, and a rewrite outside it costs a red in the same
// run rather than a pin that quietly stops asserting. That is why `readonly`,
// `export` and `local` prefixes are not accepted here and need no case: each
// fails loudly and visibly. `local` would not survive sourcing anyway, and
// `declare` is not portable to the dash and busybox shells this runs under.
//
// The quoting of the expansion is not among them, and is not pinned either.
// Quoting the substitution wraps its result; the expansion inside still has to
// carry its own quotes, or the space in `{range .status.history[*]}` splits
// the argument and kubectl is handed a truncated template. That is left
// unpinned because it fails loudly: kubectl rejects the fragment, the variable
// comes back empty, and the script's empty-history check exits 1. The `$` is
// pinned because dropping it fails quietly instead, returning the name as its
// own text and passing every check downstream. What earns a pin here is the
// silence of the failure, not its severity.
//
// An accept case is a form a maintainer may rewrite the read into, so a case
// that changes behaviour would document a broken rewrite as legitimate.
var sharedHistoryRead = regexp.MustCompile(
	`(?m)^[ \t]*[A-Za-z_][A-Za-z0-9_]*="?\$\(kubectl[^)]*jsonpath=[^)]*\$\{?HELMRELEASE_HISTORY_JSONPATH`)

func readGuardFile(t *testing.T, path string) []byte {
	t.Helper()
	src, err := os.ReadFile(filepath.Clean(path))
	if err != nil {
		t.Fatalf("reading %s: %v", path, err)
	}
	return src
}

// sourcedExpression returns the value the shell ends up with after sourcing the
// guard library, which is the value the guard passes to kubectl.
//
// This runs `sh` from a Go test, which is unusual here and deliberate. Reading
// the assignment as text means reimplementing enough of the shell to decide
// which text is the assignment, and every such approximation is wrong at some
// spelling: an `export`, an indent inside a function, a second assignment later
// in the file. Sourcing gets last-assignment-wins, `export`, `readonly` and
// top-level indentation for free, because the thing resolving them is the shell
// rather than a guess about it. What it does not get is an assignment inside a
// function: sourcing defines the function without calling it, so the value
// comes back empty and the empty check below fails, which is the right answer
// for a library that no longer sets the variable it exports.
//
// A missing `sh` fails rather than skips. A skip prints in verbose output and
// reads as a pass in the summary, so an environment without a shell would
// retire this pin silently, which is the failure mode the whole file exists to
// prevent. Anything that cannot run `sh` cannot run the script being pinned.
func sourcedExpression(t *testing.T) string {
	t.Helper()

	if _, err := exec.LookPath("sh"); err != nil {
		t.Fatalf("sh not found (%v), so the guard's own expression cannot be resolved. "+
			"This fails rather than skips: a skipped pin reads as a passing one.", err)
	}

	// The path goes in as an argument rather than into the script text, so no
	// quoting of it can change what the snippet does. `|| exit 1` is what makes
	// a broken library reach the error branch at all: without it the trailing
	// printf is the last command, so a library that fails to source still exits
	// 0 and the failure arrives only as a value that happens to look wrong.
	out, err := exec.Command("sh", "-c", `. "$1" || exit 1; printf %s "${`+sharedName+`-}"`, "sh", guardLibrary).Output()
	if err != nil {
		// Output() puts the shell's own complaint in ExitError.Stderr, and %v on
		// that error prints only the exit status. This path runs exactly when
		// something is wrong, so dropping the one sentence that says what would
		// leave the reader with the class and not the cause.
		detail := ""
		var ee *exec.ExitError
		if errors.As(err, &ee) && len(ee.Stderr) > 0 {
			detail = ": " + strings.TrimSpace(string(ee.Stderr))
		}
		t.Fatalf("sourcing %s: %v%s. The library has to be sourceable on its own, since the "+
			"e2e script sources it the same way.", guardLibrary, err, detail)
	}

	expr := string(out)
	if expr == "" {
		t.Fatalf("sourcing %s leaves %s empty. If the guard reads release history another way "+
			"now, this test has to follow it there. If it stopped reading history at all, the "+
			"e2e remediation guard asserts nothing.", guardLibrary, sharedName)
	}
	return expr
}

// A HelmRelease whose history carries the statuses the guard reads. Built from
// the upstream types, so a renamed or retyped field is a compile error here
// before it is a silent empty read against a live cluster.
func helmReleaseWithHistory() *helmv2.HelmRelease {
	return &helmv2.HelmRelease{
		Status: helmv2.HelmReleaseStatus{
			History: helmv2.Snapshots{
				{Version: 2, Status: "deployed"},
				{Version: 1, Status: "uninstalled"},
			},
		},
	}
}

// The only test here whose subject is upstream rather than the text of a shell
// script: the expression the guard ships, run over the upstream type through
// JSON the way kubectl runs it. Serialization is the point, since the struct's
// json tags are what an expression actually sees.
//
// Only the match is asserted. How kubectl's printer behaves on a path that is
// absent is kubectl's own configuration, not part of the Flux contract, and
// guessing at it here would put the expectation and the fixture back in the
// same hands.
func TestGuardExpressionReadsUpstreamHistoryStatuses(t *testing.T) {
	raw, err := json.Marshal(helmReleaseWithHistory())
	if err != nil {
		t.Fatalf("marshalling HelmRelease: %v", err)
	}
	var generic any
	if err := json.Unmarshal(raw, &generic); err != nil {
		t.Fatalf("unmarshalling HelmRelease: %v", err)
	}

	expr := sourcedExpression(t)

	jp := jsonpath.New("guard")
	if err := jp.Parse(expr); err != nil {
		t.Fatalf("parsing the guard's expression %q: %v", expr, err)
	}
	var out strings.Builder
	if err := jp.Execute(&out, generic); err != nil {
		t.Fatalf("running the guard's expression %q over an upstream HelmRelease: %v. "+
			"The serialized shape no longer satisfies the expression.", expr, err)
	}

	var got []string
	for _, line := range strings.Split(out.String(), "\n") {
		if line != "" {
			got = append(got, line)
		}
	}
	want := []string{"deployed", "uninstalled"}
	if len(got) != len(want) {
		t.Fatalf("expression %q returned %q, want one line per Snapshot status %q",
			expr, out.String(), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("status %d: got %q, want %q", i, got[i], want[i])
		}
	}
}

// The caller reads the expansion of the shared name. Naming it without
// expanding it, or naming it only in a comment beside a rewritten read, leaves
// the guard running an expression nothing here checked.
func TestGuardCallerReferencesTheSharedExpansion(t *testing.T) {
	t.Run("refuses", func(t *testing.T) {
		for _, tc := range []struct{ flaw, line string }{
			{"name not expanded", `  h=$(kubectl get hr -o"jsonpath=HELMRELEASE_HISTORY_JSONPATH")`},
			{"name only in a trailing comment", `  h=$(kubectl get hr -o"jsonpath={.status.gone}") # was ${HELMRELEASE_HISTORY_JSONPATH}`},
			{"the read is commented out", `  # history_statuses=$(kubectl get hr -o"jsonpath=${HELMRELEASE_HISTORY_JSONPATH}")`},
		} {
			t.Run(tc.flaw, func(t *testing.T) {
				if sharedHistoryRead.MatchString(tc.line) {
					t.Errorf("taken as the shared read: %s", tc.line)
				}
			})
		}
	})

	// A refuse case has to be a form the shell would not run as the read, the
	// mirror of the rule for accept cases. A legitimate rewrite listed here
	// would pin the pattern's narrowness as though it were the intent.
	t.Run("accepts", func(t *testing.T) {
		for _, tc := range []struct{ spelling, line string }{
			{"shipped form", `  history_statuses=$(kubectl get hr -o"jsonpath=${HELMRELEASE_HISTORY_JSONPATH}")`},
			{"quoted substitution", `  history_statuses="$(kubectl get hr -ojsonpath="${HELMRELEASE_HISTORY_JSONPATH}")"`},
			{"local renamed", `  hr_history=$(kubectl get hr -o"jsonpath=${HELMRELEASE_HISTORY_JSONPATH}")`},
			{"spaced -o", `  history_statuses=$(kubectl get hr -o jsonpath="${HELMRELEASE_HISTORY_JSONPATH}")`},
			{"braceless expansion", `  history_statuses=$(kubectl get hr -o"jsonpath=$HELMRELEASE_HISTORY_JSONPATH")`},
		} {
			t.Run(tc.spelling, func(t *testing.T) {
				if !sharedHistoryRead.MatchString(tc.line) {
					t.Errorf("a legitimate read was not taken as the shared read: %s", tc.line)
				}
			})
		}
	})

	if src := readGuardFile(t, guardCaller); !sharedHistoryRead.Match(src) {
		t.Errorf("%s has no read matching %s anywhere in the file. The pin needs a history "+
			"read that takes its expression from the shared assignment, and the pattern is the "+
			"exact form it accepts: either no read does that any more, or one does it in a "+
			"shape the pattern cannot see.", guardCaller, sharedHistoryRead)
	}
}

// No shell library but the one that owns the name assigns it. Sourcing the
// owning library resolves what that library ends up with, and cannot see a
// later one overwriting the name: the caller sources three, the owning one
// first, so an assignment in any of the others lands afterwards and wins.
//
// The set is asserted non-empty before it is used. A glob that stops matching
// turns "no sibling assigns the name" into a statement about nothing, and that
// reads exactly like a pass.
func TestGuardNoSiblingLibraryAssignsTheSharedName(t *testing.T) {
	t.Run("refuses", func(t *testing.T) {
		line := `  HELMRELEASE_HISTORY_JSONPATH='{range .status.history[*]}{.version}{"\n"}{end}'`
		if !nameFollowedByEquals.MatchString(line) {
			t.Errorf("a shadowing assignment went unseen: %s", line)
		}
	})

	t.Run("accepts", func(t *testing.T) {
		line := `  history_statuses=$(kubectl get hr -o"jsonpath=${HELMRELEASE_HISTORY_JSONPATH}")`
		if nameFollowedByEquals.MatchString(line) {
			t.Errorf("a plain read was taken as an assignment: %s", line)
		}
	})

	siblings, err := filepath.Glob(filepath.Join(filepath.Dir(guardLibrary), "*.sh"))
	if err != nil {
		t.Fatalf("globbing the shell libraries: %v", err)
	}
	checked := 0
	for _, path := range siblings {
		if filepath.Clean(path) == filepath.Clean(guardLibrary) {
			continue
		}
		checked++
		src := readGuardFile(t, path)
		if n := len(nameFollowedByEquals.FindAll(src, -1)); n != 0 {
			t.Errorf("%s writes %s followed by = %d times; only %s may assign it. The count is "+
				"of occurrences, so a comment mentioning one counts too; what it looks for is an "+
				"assignment in a library sourced after the one that owns the name, which would "+
				"replace the value this file checked.", path, sharedName, n, guardLibrary)
		}
	}
	if checked == 0 {
		t.Fatalf("no sibling libraries found next to %s, so this test asserted nothing", guardLibrary)
	}
}
