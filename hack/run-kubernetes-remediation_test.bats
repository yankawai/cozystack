#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Unit tests for cozy_guard_addon_helmreleases in
# hack/e2e-chainsaw/_lib/run-kubernetes.sh
#
# cozy_guard_helmrelease judges one release; cozy_guard_addon_helmreleases runs
# it over the addon releases a parent installs. One rule decides the verdict:
# the run fails when a release was REMOVED although it is configured never to
# remove itself to recover - an "uninstalled" Snapshot on a RetryOnFailure
# release, which is the tenant CNI and CSI and every Application HelmRelease.
# Everything else is reported and left green, including an "uninstalled"
# Snapshot on a release still using the default strategy, whose install
# remediation is an uninstall and which pairs it with retries: -1.
#
# kubectl is stubbed from fixture files, so these tests exercise the wiring the
# guard depends on - the name prefix that selects the addons, the readiness that
# interprets an empty history, and the failure paths of the reads themselves -
# without a cluster. The readings are unit-tested in hack/remediation-guard.bats.
#
# cozytest.sh's awk parser recognizes only @test blocks and a bare `}` on its
# own line; there is no bats `run` or `$status`. Assertions are expressed as
# direct shell tests that exit non-zero on failure. Scratch directories are
# removed at the end of the test body rather than from a trap (both runners set
# -e, so a failed test leaves its fixtures behind for inspection).
#
# Run with: hack/cozytest.sh hack/run-kubernetes-remediation_test.bats
# -----------------------------------------------------------------------------

# Writes a fixture-driven kubectl stub into $1/bin and returns with $1/fixtures
# created. The stub answers the shapes the guard issues: the namespace listing
# (from ALL_HR), one release's install strategy and Ready condition together
# (<name>.strategy and <name>.ready, joined the way the guard's jsonpath joins
# them), and its history statuses (<name>.history). A missing fixture file
# stands for a field the object does not carry, which is what kubectl prints for
# an absent jsonpath - nothing.
#
# A FAILS marker file makes the matching read exit non-zero with a message on
# stderr, which is how the API answers a timeout or a denied request. That
# looks identical to an absent field on stdout, so it is the case the guard has
# to tell apart by exit status rather than by output. Strategy and readiness
# travel in one read, so a marker on either fails that read.
#
# A WARNS marker makes the read write to stderr and still exit 0, which is what
# kubectl does for a deprecation notice or for the discovery noise a degraded
# aggregated APIService produces. No value may pick that line up: inside the
# history capture it turns an empty history into a populated one, which skips
# the readiness branch and reports an uninspected release as clean, and inside
# the strategy capture it stops the value matching RetryOnFailure, which
# downgrades a real teardown to a note.
#
# A TURNS_READY marker beside a history fixture makes serving that read write
# "True" into the release's Ready fixture, which is the interleaving the guard's
# read order has to survive: a release that completes its install between the
# two reads.
cozy_make_kubectl_stub() {
    mkdir -p "$1/bin" "$1/fixtures"
    cat > "$1/bin/kubectl" <<'STUB'
#!/bin/sh
mode=list
name=
for a in "$@"; do
  case "$a" in
    describe) mode=describe ;;
    *'status.history'*) mode=history ;;
    *'install.strategy.name'*) mode=probe ;;
    kubernetes-*) name=$a ;;
  esac
done
case "$mode" in
  list) markers=LIST ;;
  history) markers="$name.history" ;;
  probe) markers="$name.strategy $name.ready" ;;
  *) markers= ;;
esac
for m in $markers; do
  if [ -f "$FIXTURES/$m.FAILS" ]; then
    echo "Error from server: the server was unable to return a response in the time allotted" >&2
    exit 1
  fi
done
for m in $markers; do
  if [ -f "$FIXTURES/$m.WARNS" ]; then
    echo "E0806 12:00:00.000000   1 memcache.go:265] couldn't get current server API group list: the server is currently unable to handle the request" >&2
  fi
done
case "$mode" in
  list) cat "$FIXTURES/ALL_HR" ;;
  history)
    cat "$FIXTURES/$name.history" 2>/dev/null || true
    if [ -f "$FIXTURES/$name.history.TURNS_READY" ]; then
      printf 'True' > "$FIXTURES/$name.ready"
    fi
    ;;
  probe)
    printf '%s@%s' \
      "$(cat "$FIXTURES/$name.strategy" 2>/dev/null || true)" \
      "$(cat "$FIXTURES/$name.ready" 2>/dev/null || true)"
    ;;
  describe) echo "stub describe of $name" ;;
esac
exit 0
STUB
    chmod +x "$1/bin/kubectl"
}

@test "the guard is wired into the run, before the snapshot trap is disarmed" {
    lib=hack/e2e-chainsaw/_lib/run-kubernetes.sh
    # Everything else here tests the guards in isolation, which says nothing
    # about whether the run still calls them: delete both invocations and every
    # case in this file stays green while the suite asserts nothing. Ordering is
    # part of the wiring - the tenant crust-gather snapshot is taken from an EXIT
    # trap, so a guard that fired after `trap - EXIT` would report the teardown
    # with the cluster state already gone. Same shape as the ordering pin in
    # hack/run-kubernetes-schedulable_test.bats.
    # The arguments are pinned, not only the call. The addon prefix is derived
    # from the parent name inside the guard, so naming a different release here
    # would select a different set of addons and still read as wired.
    #
    # The line has to END at the call, not merely contain it, because the
    # verdict reaches the run through errexit rather than through an exit of its
    # own: appending `|| true` disarms the guard completely and leaves a
    # substring match, and every other case here, green. Indentation is left
    # free, so wrapping the call in a block stays a refactor rather than
    # becoming a red test that reports the guard as missing.
    call=$(grep -n -E '^ *cozy_guard_all_helmreleases tenant-test "kubernetes-\$\{test_name\}"$' "$lib" | head -n 1 | cut -d: -f1)
    # Keyword and signal are assembled from separate arguments, the way the
    # fixtures in hack/bats-no-exit-trap.bats do it: the scan there is lexical
    # and counts the pair wherever it appears on a line, so spelling the pattern
    # out here would read as this file installing a handler it does not install.
    disarm_re=$(printf '^  %s - %s' 'trap' 'EXIT')
    disarm=$(grep -n "$disarm_re" "$lib" | head -n 1 | cut -d: -f1)
    if [ -z "$call" ]; then
        echo "expected run_kubernetes_test to guard the parent HelmRelease and its addons" >&2
        exit 1
    fi
    if [ -z "$disarm" ]; then
        echo "expected to find the tenant-snapshot trap being disarmed in $lib" >&2
        exit 1
    fi
    if [ "$call" -ge "$disarm" ]; then
        echo "expected the guard (line $call) before the trap is disarmed (line $disarm)" >&2
        exit 1
    fi
}

@test "a failing parent still leaves every addon inspected" {
    # Two bare calls under errexit would end the script on the parent's verdict
    # and read no addon at all. The addon output is the context that explains a
    # parent failure, which is the same reason the addon loop keeps going after
    # one of its own fails. Parent here is torn down under RetryOnFailure, which
    # is fatal; the addon carries a failed Snapshot, which is a note. Both have
    # to appear, and the verdict has to stay non-zero.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-coredns\n' > "$FIXTURES/ALL_HR"
    printf 'RetryOnFailure' > "$FIXTURES/kubernetes-test-latest-version.strategy"
    printf 'uninstalled\ndeployed\n' > "$FIXTURES/kubernetes-test-latest-version.history"
    printf 'failed\ndeployed\n' > "$FIXTURES/kubernetes-test-latest-version-coredns.history"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_all_helmreleases tenant-test kubernetes-test-latest-version 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "expected the run to fail on the torn-down parent, got: $out" >&2
        exit 1
    fi
    if ! printf '%s\n' "$out" | grep -q 'was uninstalled and reinstalled, though its install strategy is RetryOnFailure'; then
        echo "expected the parent teardown to be reported, got: $out" >&2
        exit 1
    fi
    if ! printf '%s\n' "$out" | grep -q 'NOTE: kubernetes-test-latest-version-coredns carries a failed Snapshot'; then
        echo "expected the addon to still be inspected after the parent failed, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "an addon teardown alone still fails the run" {
    # The composite carries two verdicts and the addons' has to survive on its
    # own. With the parent clean, dropping the addon guard's contribution -
    # trading its collection for a bare || true - leaves every other case in
    # this file green, so the second verdict needs its own pin.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-cilium\n' > "$FIXTURES/ALL_HR"
    printf 'RetryOnFailure' > "$FIXTURES/kubernetes-test-latest-version.strategy"
    printf 'deployed\n' > "$FIXTURES/kubernetes-test-latest-version.history"
    printf 'RetryOnFailure' > "$FIXTURES/kubernetes-test-latest-version-cilium.strategy"
    printf 'uninstalled\ndeployed\n' > "$FIXTURES/kubernetes-test-latest-version-cilium.history"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_all_helmreleases tenant-test kubernetes-test-latest-version 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "expected the torn-down addon alone to fail the run, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "single-release guard passes a release that failed and recovered" {
    # The entry point the parent kubernetes-<test> release goes through, and the
    # case the guard was changed for: the apiserver stamps RetryOnFailure on
    # every Application HelmRelease, so a failed Snapshot there is an attempt
    # that kept its manifests and was retried. Failing on it - which the guard
    # did before this change - reds a run on a release that recovered by design.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'RetryOnFailure' > "$FIXTURES/kubernetes-test-latest-version.strategy"
    printf 'failed\ndeployed\n' > "$FIXTURES/kubernetes-test-latest-version.history"

    PATH="$tmp/bin:$PATH" cozy_guard_helmrelease tenant-test kubernetes-test-latest-version

    rm -rf "$tmp"
}

@test "single-release guard reports a teardown" {
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'RetryOnFailure' > "$FIXTURES/kubernetes-test-latest-version.strategy"
    printf 'uninstalled\ndeployed\n' > "$FIXTURES/kubernetes-test-latest-version.history"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_helmrelease tenant-test kubernetes-test-latest-version 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "expected failure for a history carrying an uninstalled snapshot" >&2
        exit 1
    fi
    if ! printf '%s\n' "$out" | grep -q 'HelmRelease kubernetes-test-latest-version was uninstalled and reinstalled'; then
        echo "expected the failure to name the teardown, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "addon guard passes when every addon release history is clean" {
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version\nkubernetes-test-latest-version-cilium\nkubernetes-test-latest-version-coredns\n' > "$FIXTURES/ALL_HR"
    printf 'deployed\n' > "$FIXTURES/kubernetes-test-latest-version-cilium.history"
    printf 'deployed\nsuperseded\n' > "$FIXTURES/kubernetes-test-latest-version-coredns.history"

    PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version-

    rm -rf "$tmp"
}

@test "addon guard reports a torn-down addon" {
    # The case the guard exists for: the tenant CNI was uninstalled and
    # reinstalled. RetryOnFailure never uninstalls to recover, so this teardown
    # came from somewhere else and must fail the run.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-cilium\n' > "$FIXTURES/ALL_HR"
    printf 'RetryOnFailure' > "$FIXTURES/kubernetes-test-latest-version-cilium.strategy"
    printf 'uninstalled\ndeployed\n' > "$FIXTURES/kubernetes-test-latest-version-cilium.history"

    if PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version-; then
        echo "expected failure when an addon history carries an uninstalled snapshot" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "addon guard tolerates a failure that left the manifests in place" {
    # A failed attempt on cilium or csi keeps its manifests applied and is
    # retried as an upgrade. Failing on it would red exactly the runs the retry
    # strategy was adopted to let through, so this must stay green.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-csi\n' > "$FIXTURES/ALL_HR"
    printf 'failed\ndeployed\n' > "$FIXTURES/kubernetes-test-latest-version-csi.history"

    PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version-

    rm -rf "$tmp"
}

@test "addon guard notes a failed Snapshot without failing the run" {
    # A failed Snapshot with no uninstalled beside it is the rollback path: under
    # the default strategy an upgrade is remediated by replacing the release, not
    # by removing it. Most of this chart's addons pair that strategy with
    # retries: -1, which declares repeated remediation acceptable for them, and
    # nothing measures how often they use it - so this is reported rather than
    # made fatal on the gate every PR crosses. The line has to be there: without
    # it the run says nothing at all about the cycle, which is the blindness the
    # guard was added to remove.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-coredns\n' > "$FIXTURES/ALL_HR"
    printf 'failed\ndeployed\n' > "$FIXTURES/kubernetes-test-latest-version-coredns.history"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version- 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "expected a rollback footprint to be reported, not to fail the run, got rc=$rc: $out" >&2
        exit 1
    fi
    if ! printf '%s\n' "$out" | grep -q 'NOTE: kubernetes-test-latest-version-coredns carries a failed Snapshot'; then
        echo "expected the rollback to be named in the output, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "the failed-Snapshot note does not claim a recovery that has not happened" {
    # The note is reached on any release carrying a failed Snapshot, Ready or
    # not. On one that is still not Ready the failure is live rather than
    # behind it, and a note saying it "recovered" sends a reader looking for a
    # second cause while the first one is still the answer. The release here is
    # the shape that makes the difference visible: a failed Snapshot in its
    # history and no Ready condition.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-cilium\n' > "$FIXTURES/ALL_HR"
    printf 'False' > "$FIXTURES/kubernetes-test-latest-version-cilium.ready"
    printf 'failed\n' > "$FIXTURES/kubernetes-test-latest-version-cilium.history"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version- 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "expected a failed Snapshot on a not-Ready addon to be reported, not to fail the run, got rc=$rc: $out" >&2
        exit 1
    fi
    if ! printf '%s\n' "$out" | grep -q 'carries a failed Snapshot and is not Ready'; then
        echo "expected the note to say the release is not Ready, got: $out" >&2
        exit 1
    fi
    if printf '%s\n' "$out" | grep -q 'remediated in place and recovered'; then
        echo "expected no claim of recovery on a release that is not Ready, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "addon guard notes a teardown the default strategy performed itself" {
    # An uninstalled Snapshot on a release still using the default strategy is
    # that strategy's own install remediation: it uninstalls before retrying, and
    # these addons pair it with retries: -1, so the configuration declares this
    # their recovery path. The run has no measurement of how often they take it,
    # and reddening a 25-minute bringup on a release doing what it is configured
    # to do is how a guard gets switched off. That the configuration is itself
    # the defect is true and is filed separately - it is not this guard's to
    # assert. The line must still be there: a teardown nobody reports is the
    # blindness the guard was added to remove.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-coredns\n' > "$FIXTURES/ALL_HR"
    printf 'failed\nuninstalled\ndeployed\n' > "$FIXTURES/kubernetes-test-latest-version-coredns.history"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version- 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "expected a default-strategy teardown to be reported, not to fail the run, got rc=$rc: $out" >&2
        exit 1
    fi
    if ! printf '%s\n' "$out" | grep -q 'NOTE: kubernetes-test-latest-version-coredns was uninstalled and reinstalled by its own install remediation'; then
        echo "expected the teardown to be named in the output, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "addon guard inspects every addon even after one fails" {
    # The notes the other addons print are the context that explains the
    # failure - which release rolled back, which one the default strategy tore
    # down - so stopping at the first failure hides exactly what a reader would
    # compare it against. Both releases here have something to say, and the run
    # must still end non-zero.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-cilium\nkubernetes-test-latest-version-coredns\n' > "$FIXTURES/ALL_HR"
    printf 'RetryOnFailure' > "$FIXTURES/kubernetes-test-latest-version-cilium.strategy"
    printf 'uninstalled\ndeployed\n' > "$FIXTURES/kubernetes-test-latest-version-cilium.history"
    printf 'failed\ndeployed\n' > "$FIXTURES/kubernetes-test-latest-version-coredns.history"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version- 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "expected the run to fail on the torn-down addon, got: $out" >&2
        exit 1
    fi
    if ! printf '%s\n' "$out" | grep -q 'NOTE: kubernetes-test-latest-version-coredns carries a failed Snapshot'; then
        echo "expected the addon after the failing one to still be inspected, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "addon guard fails when no addon HelmRelease matches the prefix" {
    # The parent is Ready, so its addon releases exist. An empty selection means
    # the naming this guard walks has changed, and a guard that silently
    # inspects nothing is worse than no guard at all.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version\n' > "$FIXTURES/ALL_HR"

    if PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version-; then
        echo "expected failure when the prefix selects no addon HelmRelease" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "addon guard fails a Ready addon that reports no release history" {
    # A Ready HelmRelease has a completed helm action behind it, and the
    # controller keeps a Snapshot of every one. Ready with no history is the
    # Flux status shape having moved under the guard, and passing over it would
    # leave that release unchecked while the run stayed green - the silent gap
    # this guard exists to close. The parent's own empty-history check does not
    # cover it: the parent's history says nothing about its children's.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-vsnap-crd\n' > "$FIXTURES/ALL_HR"
    printf 'True' > "$FIXTURES/kubernetes-test-latest-version-vsnap-crd.ready"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version- 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "expected failure for a Ready addon whose history came back empty" >&2
        exit 1
    fi
    if ! printf '%s\n' "$out" | grep -q 'Unexpected empty .status.history on Ready HelmRelease kubernetes-test-latest-version-vsnap-crd'; then
        echo "expected the failure to name the empty history, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "addon guard skips an addon that never completed a helm action" {
    # The parent Application HelmRelease carries disableWait, so it goes Ready
    # without waiting for the releases it applied, and the suite waits on only
    # some of them by name - metrics-server and prometheus-operator-crds among
    # those it does not. A release still working through its dependsOn has no
    # history and no teardown to find, and failing on it would be a red run with
    # a Flux-API-change message for a release that is merely still installing.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-metrics-server\n' > "$FIXTURES/ALL_HR"
    printf 'False' > "$FIXTURES/kubernetes-test-latest-version-metrics-server.ready"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version- 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "expected a not-Ready addon with no history to be skipped, got rc=$rc: $out" >&2
        exit 1
    fi
    # Skipped, but never in silence, and the line has to say it was skipped: the
    # name alone is already printed by the per-addon header above, so asserting
    # on the name would pass with the skip line deleted and the guard would be
    # reporting coverage it did not have.
    if ! printf '%s\n' "$out" | grep -q 'kubernetes-test-latest-version-metrics-server is not Ready and has no release history'; then
        echo "expected the skipped addon to be reported as not inspected, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "addon guard fails when the Ready condition cannot be read" {
    # Readiness must not conflate "read failed" with "field absent", and this is
    # where the conflation is worst: an empty Ready condition sends the release
    # down the not-Ready branch, which reports it as not inspected and returns 0.
    # A denied or timed-out read would then pass an uninspected release off as
    # covered. It travels in the same read as the strategy, so the read fails
    # whichever of the two the API could not answer.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-cilium\n' > "$FIXTURES/ALL_HR"
    : > "$FIXTURES/kubernetes-test-latest-version-cilium.ready.FAILS"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version- 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "expected failure when the Ready condition could not be read, got: $out" >&2
        exit 1
    fi
    # The message too, as with its sibling: without it the case passes when some
    # other read is the one that broke.
    if ! printf '%s\n' "$out" | grep -q 'Reading .spec.install.strategy.name and the Ready condition of kubernetes-test-latest-version-cilium failed'; then
        echo "expected the failure to name the read that carries the Ready condition, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "addon guard reads readiness before history, not after" {
    # The controller writes the Snapshot and flips Ready in one status patch, so
    # a release is never Ready before its first Snapshot exists. Reading the
    # history first and readiness afterwards observes the two in the opposite
    # order: an addon still installing at the history read and Ready one
    # round-trip later presents as Ready with an empty history, which the guard
    # fails the run on as a Flux status shape it can no longer read. Nothing
    # waits on most of these releases, so that window is open on every run. The
    # other order cannot misread, because neither truncation variant can empty a
    # non-empty history: Truncate returns early below two Snapshots, and
    # TruncateIgnoringPreviousSnapshots cuts only above five.
    #
    # The stub turns the addon Ready as a side effect of serving the history
    # read, which is that interleaving exactly: green while readiness is read
    # first, red the moment the two reads swap back.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-cilium\n' > "$FIXTURES/ALL_HR"
    : > "$FIXTURES/kubernetes-test-latest-version-cilium.history.TURNS_READY"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version- 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "expected an addon that turns Ready mid-check to be reported as not inspected, got rc=$rc: $out" >&2
        exit 1
    fi
    if ! printf '%s\n' "$out" | grep -q 'kubernetes-test-latest-version-cilium is not Ready and has no release history'; then
        echo "expected the still-installing addon to be reported as not inspected, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "addon guard fails when an addon strategy cannot be read" {
    # The strategy decides whether a teardown is fatal, so a read that timed out
    # or was denied cannot be folded into "no strategy set": that reading is the
    # lenient one, and a real teardown of the tenant CNI would be reported as the
    # default strategy's own recovery. Fail on the read instead, and say so.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-cilium\n' > "$FIXTURES/ALL_HR"
    : > "$FIXTURES/kubernetes-test-latest-version-cilium.strategy.FAILS"
    printf 'uninstalled\ndeployed\n' > "$FIXTURES/kubernetes-test-latest-version-cilium.history"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version- 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "expected failure when the install strategy could not be read" >&2
        exit 1
    fi
    if ! printf '%s\n' "$out" | grep -q 'Reading .spec.install.strategy.name and the Ready condition of kubernetes-test-latest-version-cilium failed'; then
        echo "expected the failure to name the strategy read, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "a kubectl warning does not downgrade a teardown to a note" {
    # The strategy value decides whether a teardown is fatal, and it is compared
    # for equality. kubectl writes warnings to stderr while exiting 0, so a
    # capture that took stderr would carry the warning in front of
    # RetryOnFailure, stop matching it, and report a real teardown of the tenant
    # CNI as the default strategy doing its job - the guard weakened silently,
    # through the success path, by a line that has nothing to do with the
    # release.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-cilium\n' > "$FIXTURES/ALL_HR"
    printf 'RetryOnFailure' > "$FIXTURES/kubernetes-test-latest-version-cilium.strategy"
    : > "$FIXTURES/kubernetes-test-latest-version-cilium.strategy.WARNS"
    printf 'uninstalled\ndeployed\n' > "$FIXTURES/kubernetes-test-latest-version-cilium.history"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version- 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "expected the teardown to stay fatal when kubectl warns on the strategy read, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "a kubectl warning does not turn an empty history into a clean one" {
    # kubectl writes warnings to stderr and still exits 0. If the history capture
    # takes stderr, that line becomes the history: a release with no Snapshots at
    # all reads as populated, the readiness branch never runs, and an
    # uninspected release is reported clean. The addon here is Ready with no
    # history, which must fail - and does only while the warning stays out of the
    # value.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-cilium\n' > "$FIXTURES/ALL_HR"
    : > "$FIXTURES/kubernetes-test-latest-version-cilium.history.WARNS"
    printf 'True' > "$FIXTURES/kubernetes-test-latest-version-cilium.ready"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version- 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "expected a Ready addon with no history to fail even when kubectl warns, got: $out" >&2
        exit 1
    fi
    if ! printf '%s\n' "$out" | grep -q 'Unexpected empty .status.history on Ready HelmRelease'; then
        echo "expected the empty history to be recognised as empty, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "addon guard fails when the HelmRelease listing fails" {
    # A failed listing prints nothing, exactly like a namespace with no
    # HelmReleases, so only the exit status tells them apart. Reporting the
    # empty-prefix message for an API error would send the reader after a
    # renamed release that is not the problem.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-cilium\n' > "$FIXTURES/ALL_HR"
    : > "$FIXTURES/LIST.FAILS"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version- 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "expected failure when listing the HelmReleases failed" >&2
        exit 1
    fi
    # The message, not just the status: a failed listing also empties the
    # selection, so the run fails either way and only the reason distinguishes
    # a broken API call from a release the prefix no longer matches.
    if ! printf '%s\n' "$out" | grep -q 'Listing HelmReleases in tenant-test failed'; then
        echo "expected the failure to name the listing, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "addon guard fails when an addon history cannot be read" {
    # The dangerous conflation: a timed-out or denied read yields no output,
    # which is also what a release with no history yields. Skipping on that
    # would let the guard pass over the very release it was pointed at.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-latest-version-cilium\n' > "$FIXTURES/ALL_HR"
    : > "$FIXTURES/kubernetes-test-latest-version-cilium.history.FAILS"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version- 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "expected failure when an addon history could not be read" >&2
        exit 1
    fi
    if ! printf '%s\n' "$out" | grep -q 'Reading .status.history of kubernetes-test-latest-version-cilium failed'; then
        echo "expected the failure to name the history read, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "addon selection reads the prefix literally, not as a regex" {
    # A HelmRelease name is a DNS-1123 subdomain, so a dot in one is legal, and
    # an anchored regex would read that dot as any character and pull in
    # releases belonging to no addon of this parent. Every other case here uses
    # a prefix with no metacharacter in it and so stays green either way, which
    # leaves the literal match without a carrier unless it gets a case of its
    # own - the same reason the scoping in hack/remediation-guard.bats has one.
    #
    # The listing holds a name only a wildcard reading would select, so the
    # selection must come back empty, which the guard reports as a prefix that
    # matched nothing.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-aXb-cilium\n' > "$FIXTURES/ALL_HR"

    rc=0
    out=$(PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test 'kubernetes-a.b-' 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "expected a dot in the prefix to select nothing, got: $out" >&2
        exit 1
    fi
    if ! printf '%s\n' "$out" | grep -q -F 'No addon HelmReleases matched kubernetes-a.b-'; then
        echo "expected the empty selection to be reported, got: $out" >&2
        exit 1
    fi

    rm -rf "$tmp"
}

@test "addon guard ignores HelmReleases outside the prefix" {
    # tenant-test also holds releases of other suites and of the previous
    # version's cluster. A teardown there is not this test's finding.
    . hack/e2e-chainsaw/_lib/run-kubernetes.sh
    tmp=$(mktemp -d)
    cozy_make_kubectl_stub "$tmp"
    export FIXTURES="$tmp/fixtures"
    printf 'kubernetes-test-previous-version-cilium\nkubernetes-test-latest-version-cilium\n' > "$FIXTURES/ALL_HR"
    printf 'uninstalled\ndeployed\n' > "$FIXTURES/kubernetes-test-previous-version-cilium.history"
    printf 'deployed\n' > "$FIXTURES/kubernetes-test-latest-version-cilium.history"

    PATH="$tmp/bin:$PATH" cozy_guard_addon_helmreleases tenant-test kubernetes-test-latest-version-

    rm -rf "$tmp"
}
