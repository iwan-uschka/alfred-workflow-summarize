#!/usr/bin/perl
# Text helpers for the shell scripts. Core Perl only, so the workflow needs
# nothing from Homebrew.
#
#   text.pl trim                    stdin, without leading and trailing whitespace
#   text.pl url-host STRING         prints the host and exits 0 if STRING is a URL, else exits 1
#   text.pl preview N               stdin on one line, cut to N characters plus "…"
#   text.pl cut N                   stdin cut to N characters; exits 10 when it cut something
#   text.pl count                   number of characters on stdin
#   text.pl strip-html [CHARSET]    stdin HTML without scripts, styles, navigation and media
#                                   tags, decoded with charset() and printed as UTF-8
#   text.pl decode [CHARSET]        stdin decoded with charset() and printed as UTF-8
#   text.pl clean-text              stdin with Unicode line separators turned into newlines
#                                   and runs of blank lines squeezed to one
#   text.pl fill-prompt MIN MAX LANGUAGE
#                                   stdin template with {min_bullets}, {max_bullets}
#                                   and {language} filled in
#   text.pl items QUERY WINDOW_SUBTITLE CLIPBOARD_SUBTITLE APP_ID APP_NAME
#                                   Script Filter JSON with the two rows
#   text.pl view-running JOB_DIR    Text View JSON for a job still running
#   text.pl view-final JOB_DIR      Text View JSON for a finished job
#   text.pl view-message TEXT       Text View JSON holding only TEXT
#
# Characters, not bytes: everything except strip-html and decode reads stdin
# as UTF-8, so cutting never splits a multi-byte character.
use strict;
use warnings;
use Encode qw(decode encode);
use JSON::PP;

# How often Alfred reruns the Text View script while a job is running, in
# seconds. Alfred accepts 0.1 to 5.0.
my $RERUN = 0.3;

sub slurp_bytes {
    my ($fh) = @_;
    binmode $fh;
    local $/;
    my $data = <$fh>;
    return defined $data ? $data : '';
}

# Malformed UTF-8 turns into U+FFFD instead of dying, so a half-written
# multi-byte character at the end of a growing output file is harmless.
sub utf8_in { return decode('UTF-8', $_[0]) }

sub stdin_text { return utf8_in(slurp_bytes(\*STDIN)) }

sub out_text {
    binmode STDOUT;
    print encode('UTF-8', $_[0]);
}

sub trim {
    my ($s) = @_;
    $s =~ s/\A\s+//;
    $s =~ s/\s+\z//;
    return $s;
}

sub read_file {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    return utf8_in(slurp_bytes($fh));
}

# A bad argument exits 255 on purpose. A bare die takes its exit code from
# errno when that is non-zero, which depends on the Perl build.
sub usage_error {
    print STDERR @_;
    exit 255;
}

sub positive_int {
    my ($n, $what) = @_;
    usage_error("text.pl: $what must be a whole number of 1 or more\n")
        unless defined $n && $n =~ /\A[0-9]+\z/ && $n > 0;
    return $n;
}

# A URL is one token with no whitespace, an http or https scheme in any case,
# and a non-empty host. A lone "http://" has no host, so it is text.
sub url_host {
    my ($s) = @_;
    return undef if $s =~ /\s/;
    return undef unless $s =~ m{\Ahttps?://([^/?#]*)}i;
    my $host = $1;
    $host =~ s/\A.*@//;         # user:password@
    $host =~ s/:[0-9]*\z//;     # :port
    return length $host ? lc $host : undef;
}

# Browsers decode these labels with a wider charset than Encode's codec of
# the same name: Latin-1 pages carry Windows-1252 quotes and dashes, and
# GB2312 pages carry GBK characters.
my %BROWSER_LABEL = (
    'iso-8859-1' => 'cp1252', 'latin1' => 'cp1252',
    'us-ascii'   => 'cp1252', 'ascii'  => 'cp1252',
    'gb2312'     => 'gbk',
);

# charset(NAME, ...): the first name Encode knows, else UTF-8. An unknown
# name falls through to the next one instead of failing the page. UTF-7 and
# the MIME codecs are not page charsets and are skipped like unknown names.
sub charset {
    for my $name (@_) {
        next unless defined $name && length $name;
        my $enc = Encode::find_encoding($BROWSER_LABEL{lc $name} // $name);
        next unless $enc;
        next if $enc->name =~ /\A(?:UTF-7|MIME-)/i;
        return $enc->name;
    }
    return 'UTF-8';
}

# Every charset a page declares in <meta charset="..."> or in
# <meta http-equiv="Content-Type" content="...; charset=...">, in page order.
# A page whose bytes can carry a <meta> tag readable as ASCII is not UTF-16,
# UTF-32 or UCS-2, so those names mean UTF-8, as in browsers.
sub meta_charsets {
    my ($h) = @_;
    my @names;
    for my $meta ($h =~ /<meta\b[^>]*>/gi) {
        next unless $meta =~ /\bcharset\s*=\s*["']?([A-Za-z0-9_.:-]+)/i;
        my $name = $1;
        my $enc = Encode::find_encoding($name);
        push @names, $enc && $enc->name =~ /\A(?:UTF-(?:16|32)|UCS-[24])/i ? 'UTF-8' : $name;
    }
    return @names;
}

sub json_out {
    my ($data) = @_;
    binmode STDOUT;
    print JSON::PP->new->utf8->canonical->encode($data), "\n";
}

sub join_parts { return join "\n\n", grep { length } map { trim($_) } @_ }

my %commands = (
    'trim' => sub { out_text(trim(stdin_text())) },

    'url-host' => sub {
        my $host = url_host(utf8_in(defined $_[0] ? $_[0] : ''));
        exit 1 unless defined $host;
        out_text("$host\n");
    },

    'preview' => sub {
        my $n = positive_int($_[0], 'N');
        my $s = trim(stdin_text());
        $s =~ s/\s+/ /g;
        $s = substr($s, 0, $n) . "\x{2026}" if length($s) > $n;
        out_text($s);
    },

    'cut' => sub {
        my $n = positive_int($_[0], 'N');
        my $s = stdin_text();
        if (length($s) > $n) {
            out_text(substr($s, 0, $n));
            exit 10;
        }
        out_text($s);
    },

    'count' => sub { print length(stdin_text()), "\n" },

    'decode' => sub { out_text(decode(charset($_[0]), slurp_bytes(\*STDIN))) },

    # The charset from the HTTP header (the argument) wins over the page's
    # own <meta>, which this removes along with the rest of <head>. The
    # output is UTF-8, so textutil needs no charset of its own.
    'strip-html' => sub {
        my $bytes = slurp_bytes(\*STDIN);
        $bytes =~ s/<!--.*?-->//gs;
        my $h = decode(charset($_[0], meta_charsets($bytes)), $bytes);
        # A page with exactly one <main> keeps only that, which drops site
        # navigation that is not marked up as <nav>.
        my @mains = $h =~ /<main(?![\w-])/gi;
        if (@mains == 1 && $h =~ m{(<main(?![\w-])[^>]*>.*</main\s*>)}si) {
            $h = "<html><body>$1</body></html>";
        }
        # <form> itself stays: some sites wrap the whole page in one.
        for my $tag (qw(head script style noscript template svg math iframe
                        object canvas nav aside footer button select textarea)) {
            $h =~ s{<$tag(?![\w-])[^>]*>.*?</$tag\s*>}{}gsi;
        }
        # Tags that make textutil load a resource. textutil waits for those
        # and gives up after 60 seconds on a typical news page.
        $h =~ s{<(?:img|link|meta|base|video|audio|source|picture|embed|input|track)\b[^>]*>}{}gsi;
        out_text($h);
    },

    'clean-text' => sub {
        my $s = stdin_text();
        $s =~ s/\r\n?/\n/g;
        $s =~ s/[\x{2028}\x{2029}]/\n/g;
        $s =~ s/[ \t\x{a0}]+$//mg;
        $s =~ s/\n{3,}/\n\n/g;
        out_text(trim($s) . "\n");
    },

    'fill-prompt' => sub {
        my ($min, $max, $language) = @_;
        $language = utf8_in(defined $language ? $language : '');
        $language = 'the same language as the input' unless length trim($language);
        my $s = stdin_text();
        $s =~ s/\{min_bullets\}/$min/g;
        $s =~ s/\{max_bullets\}/$max/g;
        $s =~ s/\{language\}/$language/g;
        out_text($s);
    },

    'items' => sub {
        my ($query, $window_sub, $clip_sub, $app_id, $app_name) =
            map { utf8_in(defined $_ ? $_ : '') } @_[0 .. 4];
        my $q = lc trim($query);
        my $vars = { sum_app_id => $app_id, sum_app_name => $app_name };
        # No uid, so Alfred never reorders the rows by usage.
        my @rows = (
            { title => 'Active window', subtitle => $window_sub, arg => 'window',
              valid => JSON::PP::true, variables => $vars },
            { title => 'Clipboard', subtitle => $clip_sub, arg => 'clipboard',
              valid => JSON::PP::true, variables => $vars },
        );
        json_out({ items => [ grep { index(lc $_->{title}, $q) >= 0 } @rows ] });
    },

    'view-running' => sub {
        my ($job) = @_;
        my $job_chars = utf8_in($job);   # for JSON only; keep $job (bytes) for file paths
        my $body = read_file("$job/out");
        $body = read_file("$job/status") unless length trim($body);
        json_out({
            rerun     => $RERUN,
            response  => join_parts(read_file("$job/notice"), $body),
            variables => { sum_job => $job_chars },
            behaviour => { response => 'replace', scroll => 'end' },
        });
    },

    'view-final' => sub {
        my ($job) = @_;
        json_out({
            response  => join_parts(read_file("$job/notice"), read_file("$job/out"),
                                    read_file("$job/msg")),
            variables => { sum_job => '' },
            behaviour => { response => 'replace', scroll => 'start' },
        });
    },

    'view-message' => sub {
        json_out({
            response  => trim(utf8_in(defined $_[0] ? $_[0] : '')),
            variables => { sum_job => '' },
            behaviour => { response => 'replace', scroll => 'start' },
        });
    },
);

my $cmd = shift @ARGV;
usage_error("usage: text.pl <command> [args]\n") unless defined $cmd && $commands{$cmd};
$commands{$cmd}->(@ARGV);
