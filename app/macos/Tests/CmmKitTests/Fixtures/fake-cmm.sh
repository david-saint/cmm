#!/bin/sh
# A stand-in for the real cmm, used only by the Swift tests. It speaks the CLI contract of
# conductor/tracks/app_v0_20261015/spec.md with canned output and records what it was asked, so the tests can
# check the app's side of the conversation without ever running a real cleanup.
#
#   cmm plan --json                                  prints the plan in $FAKE_CMM_PLAN
#   cmm apply --yes --json --select-file FILE        prints NDJSON events for the selected paths
#
# Anything else is refused with status 64. It never deletes or writes anything except its own records.
#
# Environment (set by the tests):
#   FAKE_CMM_DIR      folder the fake records into (required): invocations.log, env.txt, pid, selection.*, and for
#                     `apply` ready (it handles SIGINT from now on) and interrupted (it got one)
#   FAKE_CMM_PLAN     plan JSON file; `apply` treats its items as "the fresh plan"
#   FAKE_CMM_MODE     normal (default), or one of:
#       plan-error    `plan` fails with status 2 and a message on stderr
#       garbage-plan  `plan` prints text that is not JSON
#       plan-hang     `plan` waits for $FAKE_CMM_RELEASE (at most 20 s)
#       noisy         1 MB on stderr first (the pipe must be drained or the run would hang), then as normal
#       fail-item     the second matched item fails; `done` says failed:1; exit status 1
#       fatal         no events at all, a message on stderr, exit status 1
#       no-done       events but no `done`, exit status 0
#       no-done-fail  events but no `done`, a message on stderr, exit status 1
#       bad-line      one line that is not JSON between the events
#       big           5000 items
#       slow          waits for $FAKE_CMM_RELEASE after the first item; SIGINT ends it with done/stopped:true
#       slow-start    has read the selection file but waits for $FAKE_CMM_RELEASE before its `start` event (the
#                     real cmm plans again first); SIGINT ends it at once with status 130 and no output
#   FAKE_CMM_RELEASE  file the test creates to let a `slow` or `plan-hang` run continue
set -u

dir=${FAKE_CMM_DIR:?FAKE_CMM_DIR is not set}
mode=${FAKE_CMM_MODE:-normal}

echo "$*" >> "$dir/invocations.log"
env | sort > "$dir/env.txt"
echo $$ > "$dir/pid"

case "${1:-}" in
plan)
    if [ $# -ne 2 ] || [ "$2" != "--json" ]; then
        echo "fake-cmm: expected exactly: plan --json (got: $*)" >&2
        exit 64
    fi
    case $mode in
    plan-error)
        echo "cmm: cannot read the free space" >&2
        exit 2
        ;;
    garbage-plan)
        echo "Checking what can safely go..."
        exit 0
        ;;
    plan-hang)
        i=0
        while [ ! -e "${FAKE_CMM_RELEASE:-/nonexistent}" ] && [ $i -lt 400 ]; do
            sleep 0.05
            i=$((i + 1))
        done
        exit 3
        ;;
    noisy)
        head -c 1000000 /dev/zero | tr '\0' 'x' >&2
        echo >&2
        ;;
    esac
    cat "${FAKE_CMM_PLAN:?FAKE_CMM_PLAN is not set}"
    ;;

apply)
    if [ $# -ne 5 ] || [ "$2" != "--yes" ] || [ "$3" != "--json" ] || [ "$4" != "--select-file" ]; then
        echo "fake-cmm: expected exactly: apply --yes --json --select-file FILE (got: $*)" >&2
        exit 64
    fi
    sel=$5
    if [ ! -f "$sel" ]; then
        echo "fake-cmm: selection file not found: $sel" >&2
        exit 64
    fi
    # What the app did to the selection file, as seen by the process that reads it.
    cp "$sel" "$dir/selection.json"
    stat -f %Lp "$sel" > "$dir/selection.mode"
    stat -f %Lp "$(dirname "$sel")" > "$dir/selection.dir.mode"
    echo "$sel" > "$dir/selection.path"

    if [ "$mode" = "fatal" ]; then
        echo "cmm: cannot plan: the volume is not mounted" >&2
        exit 1
    fi
    if [ "$mode" = "noisy" ]; then
        head -c 1000000 /dev/zero | tr '\0' 'x' >&2
        echo >&2
    fi
    exec /usr/bin/perl - "$mode" "${FAKE_CMM_PLAN:?FAKE_CMM_PLAN is not set}" "$sel" "$dir" <<'PERL'
use strict;
use warnings;
use JSON::PP;

$| = 1;
my ($mode, $plan_file, $sel_file, $dir) = @ARGV;
my $json = JSON::PP->new->canonical->utf8;

sub slurp {
    my $file = shift;
    open(my $fh, '<:raw', $file) or die "fake-cmm: cannot open $file: $!";
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}
sub emit { print $json->encode($_[0]), "\n" }
sub note { my ($name, $text) = @_; open(my $fh, '>', "$dir/$name") or return; print $fh $text; close $fh }

my $stopped = 0;
$SIG{INT} = sub { $stopped = 1; note('interrupted', "1\n") };
note('ready', "1\n");   # from here on a SIGINT is handled, not fatal: tests wait for this before interrupting
alarm 30;   # a watchdog: this fake never outlives a broken test

my @selected = @{ $json->decode(slurp($sel_file)) };
my $plan = $json->decode(slurp($plan_file));
my %fresh = map { $_->{path} => $_ } @{ $plan->{items} };
my $free = $plan->{host}{free_bytes};

my @matched = grep { exists $fresh{$_} } @selected;
my $matched_bytes = 0;
$matched_bytes += $fresh{$_}{bytes} for @matched;

if ($mode eq 'slow-start') {
    my $started = time;
    while (!-e ($ENV{FAKE_CMM_RELEASE} // '/nonexistent') && !$stopped && time - $started < 20) {
        select(undef, undef, undef, 0.02);
    }
    exit 130 if $stopped;
}

emit({ event => 'start', schema_version => 1, selected => scalar(@selected), matched => scalar(@matched),
       bytes => $matched_bytes + 0, free_bytes => $free + 0 });

my ($deleted, $skipped, $failed, $freed) = (0, 0, 0, 0);
my ($seen_matched, $waited) = (0, 0);
my $limit = $mode eq 'big' ? 5000 : scalar(@selected);

my @work = @selected;
if ($mode eq 'big') { @work = map { "/Users/test/big/item-$_" } 1 .. $limit }

ITEM:
for my $path (@work) {
    my $item = $fresh{$path};
    my ($status, $reason, $bytes, $freed_bytes) = ('skipped', 'not in the current plan', 0, 0);
    if ($mode eq 'big') {
        ($status, $reason, $bytes, $freed_bytes) = ('deleted', '', 10, 10);
    } elsif ($item) {
        $seen_matched++;
        $bytes = $item->{bytes};
        if ($mode eq 'fail-item' && $seen_matched == 2) {
            ($status, $reason) = ('failed', 'remove failed: permission denied');
        } else {
            ($status, $reason, $freed_bytes) = ('deleted', '', $bytes);
        }
    }
    emit({ event => 'item', rule => ($item ? $item->{rule} : ''), group => ($item ? $item->{group} : ''),
           path => $path, status => $status, reason => $reason, bytes => $bytes + 0, freed_bytes => $freed_bytes + 0 });
    if    ($status eq 'deleted') { $deleted++; $freed += $freed_bytes }
    elsif ($status eq 'failed')  { $failed++ }
    else                         { $skipped++ }

    if ($mode eq 'bad-line' && $deleted == 1 && $status eq 'deleted') {
        print "this line is not JSON {\n";
    }
    if ($mode eq 'slow' && !$waited) {
        $waited = 1;
        my $started = time;
        while (!-e ($ENV{FAKE_CMM_RELEASE} // '/nonexistent') && !$stopped && time - $started < 20) {
            select(undef, undef, undef, 0.02);
        }
    }
    last ITEM if $stopped;
}

exit 0 if $mode eq 'no-done';
if ($mode eq 'no-done-fail') {
    print STDERR "cmm: lost the plan halfway\n";
    exit 1;
}

emit({ event => 'done', deleted => $deleted, skipped => $skipped, failed => $failed, freed_bytes => $freed,
       free_before => $free + 0, free_after => $free + $freed, stopped => ($stopped ? JSON::PP::true : JSON::PP::false),
       warnings => [], log => '/Users/test/.local/state/cmm/cleanup.log' });
exit($failed > 0 ? 1 : 0);
PERL
    ;;

*)
    echo "fake-cmm: unknown command: $*" >&2
    exit 64
    ;;
esac
