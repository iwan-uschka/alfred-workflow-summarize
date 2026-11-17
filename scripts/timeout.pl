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
# Exit status: COMMAND's own, 124 on timeout (the same code as GNU timeout),
# 125 for a bad SECONDS value, 127 when COMMAND cannot be started.
use strict;
use warnings;
use POSIX ();

# Seconds between the polite TERM and the KILL for a command that ignores it.
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

my $pid = fork;
die "timeout.pl: fork failed: $!\n" unless defined $pid;
if ($pid == 0) {
    setpgrp(0, 0);
    { no warnings 'exec'; exec { $ARGV[0] } @ARGV; }
    print STDERR "timeout.pl: cannot run $ARGV[0]: $!\n";
    POSIX::_exit(127);
}
# Set the group from this side too, so a kill sent right after the fork
# cannot miss a child that has not called setpgrp yet.
setpgrp($pid, $pid);

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

my $done;
do { $done = waitpid($pid, 0) } while ($done == -1 && $!{EINTR});
my $status = $?;
alarm 0;
# The command may have died on the TERM while something else in its group
# ignored it. Cancelling the alarm cancelled that one's KILL, so send it now.
kill 'KILL', -$pid if $timed_out;

exit 143 if $stopping;
exit 124 if $timed_out;
exit($status >> 8) if ($status & 127) == 0;
exit(128 + ($status & 127));
