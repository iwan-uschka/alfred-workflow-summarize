#!/usr/bin/perl
# timeout.pl SECONDS COMMAND [ARGS...]
#
# Runs COMMAND and kills it if it is still running after SECONDS. macOS has
# no timeout(1), so this does the same job in core Perl.
#
# COMMAND runs in its own process group, and the kill goes to the whole
# group, so a shell wrapper and everything it started stop together. A
# TERM sent to this script is passed on to the group the same way, which is
# how stopping a job also stops the backend it is waiting on.
#
# When SUM_PGID_FILE names a file, the command's process group is written to
# it as soon as the group exists, and the file is removed once the command
# has been reaped. A caller that has to kill this script can then still stop
# the command by signalling the recorded group.
#
# Exit status: COMMAND's own, 124 on timeout (the same code as GNU timeout),
# 125 for a bad SECONDS value, 127 when COMMAND cannot be started.
use strict;
use warnings;
use POSIX ();

# Seconds between the polite TERM and the KILL for a command that ignores it.
# summarize.sh's STOP_WAIT_TENTHS must stay well above this, or stopping an
# old job KILLs timeout.pl before it has killed the backend.
my $GRACE = 2;

# A larger value would switch the timeout off instead of setting it: alarm
# wraps anything above 32 bits, and the macOS kernel refuses a timer longer
# than 100000000 seconds.
my $MAX_SECS = 100000000;

my $secs = shift @ARGV;
unless (defined $secs && $secs =~ /\A[0-9]+\z/ && $secs > 0 && $secs <= $MAX_SECS && @ARGV) {
    print STDERR "usage: timeout.pl SECONDS COMMAND [ARGS...]\n";
    exit 125;
}

# TERM stays blocked from before the fork until the handlers exist. A TERM
# in between would otherwise kill this script and leave the command running
# with no watchdog. A blocked TERM waits and arrives once unblocked. The
# command gets the caller's mask back, but this script always unblocks TERM,
# even for a caller that had it blocked, because passing TERM on is its job.
my $term = POSIX::SigSet->new(POSIX::SIGTERM());
my $old_mask = POSIX::SigSet->new();
POSIX::sigprocmask(POSIX::SIG_BLOCK(), $term, $old_mask);

my $pid = fork;
die "timeout.pl: fork failed: $!\n" unless defined $pid;
if ($pid == 0) {
    setpgrp(0, 0);
    POSIX::sigprocmask(POSIX::SIG_SETMASK(), $old_mask);
    { no warnings 'exec'; exec { $ARGV[0] } @ARGV; }
    print STDERR "timeout.pl: cannot run $ARGV[0]: $!\n";
    POSIX::_exit(127);
}
# Set the group from this side too, so a kill sent right after the fork
# cannot miss a child that has not called setpgrp yet.
setpgrp($pid, $pid);
my $pgid_file = $ENV{SUM_PGID_FILE};
undef $pgid_file if defined $pgid_file && $pgid_file eq '';
if (defined $pgid_file && open(my $fh, '>', $pgid_file)) {
    print $fh "$pid\n";
    close $fh;
}

my $timed_out = 0;
my $stopping = 0;
$SIG{ALRM} = sub {
    if ($timed_out) {
        kill 'KILL', -$pid;
    } else {
        $timed_out = 1;
        kill 'TERM', -$pid;
        alarm $GRACE;
    }
};
$SIG{TERM} = sub {
    $stopping = 1;
    $timed_out = 1;      # the next ALRM sends KILL
    kill 'TERM', -$pid;
    alarm $GRACE;
};
alarm $secs;
POSIX::sigprocmask(POSIX::SIG_UNBLOCK(), $term);

my $done;
do { $done = waitpid($pid, 0) } while ($done == -1 && $!{EINTR});
my $status = $?;
alarm 0;
unlink $pgid_file if defined $pgid_file;
# The command may have died on the TERM while something else in its group
# ignored it. Cancelling the alarm cancelled that one's KILL, so send it now.
kill 'KILL', -$pid if $timed_out;

exit 143 if $stopping;
exit 124 if $timed_out;
exit($status >> 8) if ($status & 127) == 0;
exit(128 + ($status & 127));
