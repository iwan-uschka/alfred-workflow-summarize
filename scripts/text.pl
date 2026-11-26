#!/usr/bin/perl
# Text helpers for the shell scripts. Core Perl only, so the workflow needs
# nothing from Homebrew.
#
#   text.pl trim                    stdin, without leading and trailing whitespace
#   text.pl url-host                prints the host and exits 0 if stdin is a URL, else exits 1
#   text.pl public-ip               exits 0 if stdin is a public IP address, else exits 1:
#                                   loopback, private, link-local, shared, multicast,
#                                   documentation, IPv6 forms embedding such an IPv4
#                                   address, or unparseable (internal_ip lists the ranges)
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
#   text.pl view-running JOB_DIR    Text View JSON for a job still running, without
#                                   Markdown images, live links or HTML tags
#   text.pl view-final JOB_DIR      the same for a finished job
#   text.pl view-message TEXT       Text View JSON holding only TEXT
#
# Characters, not bytes: everything except strip-html and decode reads stdin
# as UTF-8, so cutting never splits a multi-byte character.
use strict;
use warnings;
use Socket ();
use Encode qw(decode encode);
use JSON::PP;

# How often Alfred reruns the Text View script while a job is running, in
# seconds. Alfred accepts 0.1 to 5.0.
my $RERUN = 0.3;

# Longer than this many characters, the clipboard is text, not a URL. The
# Script Filter and the job both ask url-host, so they agree.
my $MAX_URL_CHARS = 2048;

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
# a non-empty host, and at most $MAX_URL_CHARS characters. A lone "http://"
# has no host, so it is text.
sub url_host {
    my ($s) = @_;
    return undef if length $s > $MAX_URL_CHARS;
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

# The command's output derives from text an attacker may have written, and
# the Text View may render Markdown. So no image, link or HTML tag in it may
# point at a remote resource. Images become "[image: alt]", links keep only
# their text, and reference definitions and HTML tags lose their syntax. A
# construct cut off at the end while the command still prints gets the same
# treatment, so the text keeps its shape when the rest arrives. Removing one
# construct can join the text around it into another, so the passes repeat
# until nothing changes. Each change removes a "<", "!" or "[", so they end.
# Bracketed text may span lines, but not a blank line, as in Markdown, and a
# backslash escapes the next character. With every reference definition
# broken, a reference link is plain text, so only inline links need a rule.
my $LINE     = qr/[^\[\]\n\\]++|\\[^\n]?|\n(?![ \t]*\n)/;
my $BRACKETS = qr/(\[(?:$LINE|(?-1))*+\])/;
my $DEST     = qr/\((?:[^()\n]++|\([^()\n]*\))*+\)?/;

sub no_remote {
    my ($s) = @_;
    my $before;
    do {
        $before = $s;
        $s =~ s/<!--.*?(?:-->|\z)//sg;
        $s =~ s/<((?:https?|mailto):[^<>\s]*)>/$1/gi;
        1 while $s =~ s/<[\/!?]?[A-Za-z][^<>]*(?:>|\z)//;
        $s =~ s/\[((?:[^\[\]\\]|\\.)+)\]:/$1:/sg;
        1 while $s =~ s/(?<!!)$BRACKETS$DEST/substr($1, 1, -1)/e;
        1 while $s =~ s/!$BRACKETS(?:$DEST|\[[^\]\n]*\]?)?/'[image: ' . substr($1, 1, -1) . ']'/e;
        $s =~ s/!\[((?:$LINE)*)\z/[image: $1]/;
    } while $s ne $before;
    return $s;
}

# Returns 1 unless the trimmed argument is a public IP address. Refused:
# unparseable input; IPv4 0/8, 10/8, 100.64/10, 127/8, 169.254/16, 172.16/12,
# 192.0.0/24, 192.168/16, 198.18/15 and 224/4 and above; IPv6 :: and ::1,
# fc00::/7, fe80::/10, ff00::/8 and 2001:db8::/32. IPv6 addresses that embed
# an IPv4 address are judged by that IPv4 address: ::ffff:a.b.c.d,
# ::ffff:0:a.b.c.d, ::a.b.c.d, NAT64 64:ff9b::/96 and 6to4 2002::/16.
sub internal_ip {
    my $ip = trim($_[0]);
    my $bin = Socket::inet_pton(Socket::AF_INET6(), $ip);
    if (defined $bin) {
        my @w = unpack 'n8', $bin;
        # IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d) addresses
        # are judged as the IPv4 address inside them.
        if (!grep({ $_ } @w[0 .. 4]) && ($w[5] == 0xffff || $w[5] == 0)
            && ($w[5] == 0xffff || $w[6] || $w[7] > 1)) {
            return internal_ip(join '.', unpack 'C4', substr($bin, 12));
        }
        return 1 if $w[0] == 0 && !grep({ $_ } @w[1 .. 6]) && $w[7] <= 1;   # :: and ::1
        return 1 if ($w[0] & 0xfe00) == 0xfc00;   # fc00::/7 unique local
        return 1 if ($w[0] & 0xffc0) == 0xfe80;   # fe80::/10 link-local
        return 1 if ($w[0] & 0xff00) == 0xff00;   # multicast
        return internal_ip(join '.', unpack 'C4', substr($bin, 12))
            if !grep({ $_ } @w[0 .. 3]) && $w[4] == 0xffff && $w[5] == 0;   # ::ffff:0:a.b.c.d translated
        return internal_ip(join '.', unpack 'C4', substr($bin, 12))
            if $w[0] == 0x64 && $w[1] == 0xff9b && !grep({ $_ } @w[2 .. 5]);   # NAT64
        return internal_ip(join '.', unpack 'C4', substr($bin, 2, 4))
            if $w[0] == 0x2002;                                                 # 6to4
        return 1 if $w[0] == 0x2001 && $w[1] == 0x0db8;                         # documentation
        return 0;
    }
    $bin = Socket::inet_pton(Socket::AF_INET(), $ip);
    return 1 unless defined $bin;
    my ($a, $b, $c) = unpack 'C3', $bin;
    return 1 if $a == 0 || $a == 10 || $a == 127 || $a >= 224;
    return 1 if $a == 100 && ($b & 0xc0) == 64;    # 100.64/10 shared space
    return 1 if $a == 169 && $b == 254;
    return 1 if $a == 172 && ($b & 0xf0) == 16;
    return 1 if $a == 192 && $b == 168;
    return 1 if $a == 192 && $b == 0 && $c == 0;
    return 1 if $a == 198 && ($b & 0xfe) == 18;
    return 0;
}

my %commands = (
    # Exits 0 only for a public address, so a caller that refuses on any other
    # exit code also refuses when this script itself fails.
    'public-ip' => sub { exit(internal_ip(stdin_text()) ? 1 : 0) },

    'trim' => sub { out_text(trim(stdin_text())) },

    'url-host' => sub {
        my $host = url_host(stdin_text());
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
        my $body = no_remote(read_file("$job/out"));
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
            response  => join_parts(read_file("$job/notice"),
                                    map { no_remote(read_file("$job/$_")) } qw(out msg)),
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
