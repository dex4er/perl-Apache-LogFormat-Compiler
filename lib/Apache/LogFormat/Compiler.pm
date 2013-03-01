package Apache::LogFormat::Compiler;

use strict;
use warnings;
use 5.008005;
use Carp;
use POSIX ();
use Plack::Util;

our $VERSION = '0.01';

# copy from Plack::Middleware::AccessLog

my %formats = (
    common => '%h %l %u %t "%r" %>s %b',
    combined => '%h %l %u %t "%r" %>s %b "%{Referer}i" "%{User-agent}i"',
);

my $tzoffset = POSIX::strftime("%z", localtime) !~ /^[+-]\d{4}$/ && do {
    require Time::Local;
    my @t = localtime;
    my $seconds = Time::Local::timegm(@t) - Time::Local::timelocal(@t);
    my $min_offset = int($seconds / 60);
    sprintf '%+03d%02u', $min_offset / 60, $min_offset % 60;
};

sub _strftime {
    my ($fmt, @time) = @_;
    $fmt =~ s/%z/$tzoffset/g if $tzoffset;
    my $old_locale = POSIX::setlocale(&POSIX::LC_ALL);
    POSIX::setlocale(&POSIX::LC_ALL, 'C');
    my $out = POSIX::strftime($fmt, @time);
    POSIX::setlocale(&POSIX::LC_ALL, $old_locale);
    return $out;
};

sub _safe {
    my $string = shift;
    $string =~ s/([^[:print:]])/"\\x" . unpack("H*", $1)/eg
        if defined $string;
    $string;
}

sub _string {
    my $string = shift;
    return '-' if ! defined $string;
    return '-' if ! length $string;
    _safe($string);
}

my $block_handler = sub {
    my($block, $type) = @_;
    my $cb;
    if ($type eq 'i') {
        $block =~ s/-/_/g;
        $cb =  q!_string($env->{"HTTP_" . uc('!.$block.q!')})!;
    } elsif ($type eq 'o') {
        $cb =  q!_string(scalar $h->get('!.$block.q!'))!;
    } elsif ($type eq 't') {
        $cb =  q!"[" . _strftime('!.$block.q!', localtime) . "]"!;
    } else {
        Carp::croak("{$block}$type not supported");
        $cb = "-";
    }
    return q|! . | . $cb . q|
      . q!|;
};

our %char_handler = (
    '%' => q!'%'!,
    h => q!($env->{REMOTE_ADDR} || '-')!,
    l => q!'-'!,
    u => q!($env->{REMOTE_USER} || '-')!,
    t => q!"[" . _strftime('%d/%b/%Y:%H:%M:%S %z', localtime) . "]"!,
    r => q!_safe($env->{REQUEST_METHOD}) . " " . _safe($env->{REQUEST_URI}) .
                       " " . $env->{SERVER_PROTOCOL}!,
    s => q!$res->[0]!,
    b => q!(defined $length ? $length : '-')!,
    T => q!int($time*1_000_000)!,
    D => q!$time!,
    v => q!($env->{SERVER_NAME} || '-')!,
    V => q!($env->{HTTP_HOST} || $env->{SERVER_NAME} || '-')!,
    p => q!$env->{SERVER_PORT}!,
    P => q!$$!,
);

my $char_handler = sub {
    my $char = shift;
    my $cb = $char_handler{$char};
    unless ($cb) {
        Carp::croak "\%$char not supported.";
        return "-";
    }
    q|! . | . $cb . q|
      . q!|;
};

sub new {
    my $class = shift;

    my $fmt = shift || "combined";
    $fmt = $formats{$fmt} if exists $formats{$fmt};

    my $self = bless {
        fmt => $fmt
    }, $class; 
    $self->compile();
    return $self;
}

sub compile {
    my $self = shift;
    my $fmt = $self->{fmt};
    $fmt =~ s/!/\\!/g;
    $fmt =~ s!
        (?:
             \%\{(.+?)\}([a-z]) |
             \%(?:[<>])?([a-zA-Z\%])
        )
    ! $1 ? $block_handler->($1, $2) : $char_handler->($3) !egx;
    $fmt = q|sub {
        my ($env,$res,$length,$time) = @_;
        my $h = Plack::Util::headers($res->[1]);
        q!| . $fmt . q|!
    }|;
    $self->{log_handler_code} = $fmt;
    $self->{log_handler} = eval $fmt;
}

sub log_line {
    my $self = shift;
    my ($env,$res,$length,$time) = @_;
    my $log = $self->{log_handler}->($env,$res,$length,$time);
    $log . "\n";
}

1;
__END__

=encoding utf8

=head1 NAME

Apache::LogFormat::Compiler - Compile LogFormat to perl-code 

=head1 SYNOPSIS

  use Apache::LogFormat::Compiler;

  my $log_handler = Apache::LogFormat::Compiler->new();
  my $log = $log_handler->log_line(
      $env,
      $res,
      $length,
      $time
  );

=head1 DESCRIPTION

Compile LogFormat to perl-code. For faster generating log_line.

B<THIS IS A DEVELOPMENT RELEASE. API MAY CHANGE WITHOUT NOTICE>.

=head1 METHOD

=over 4

=item new($fmt:String)

Takes a format string (or a preset template C<combined> or C<custom>)
to specify the log format. This middleware implements a subset of
L<Apache's LogFormat templates|http://httpd.apache.org/docs/2.0/mod/mod_log_config.html>:

   %%    a percent sign
   %h    REMOTE_ADDR from the PSGI environment, or -
   %l    remote logname not implemented (currently always -)
   %u    REMOTE_USER from the PSGI environment, or -
   %t    [local timestamp, in default format]
   %r    REQUEST_METHOD, REQUEST_URI and SERVER_PROTOCOL from the PSGI environment
   %s    the HTTP status code of the response
   %b    content length
   %T    custom field for handling times in subclasses
   %D    custom field for handling sub-second times in subclasses
   %v    SERVER_NAME from the PSGI environment, or -
   %V    HTTP_HOST or SERVER_NAME from the PSGI environment, or -
   %p    SERVER_PORT from the PSGI environment
   %P    the worker's process id

Some of these format fields are only supported by middleware that subclasses C<AccessLog>.

In addition, custom values can be referenced, using C<%{name}>,
with one of the mandatory modifier flags C<i>, C<o> or C<t>:

   %{variable-name}i    HTTP_VARIABLE_NAME value from the PSGI environment
   %{header-name}o      header-name header
   %{time-format]t      localtime in the specified strftime format

=item log_line($env:HashRef,$res:ArrayRef,$length:Integer,$time:Integer): $log:String

PSGI-style $env and $res, Content-Length and the time taken to serve request in microseconds.

=back

=head1 AUTHOR

Masahiro Nagano E<lt>kazeburo@gmail.comE<gt>

=head1 SEE ALSO

L<Plack::Middleware::AccessLog>, L<http://httpd.apache.org/docs/2.2/mod/mod_log_config.html>

=head1 LICENSE

Copyright (C) Masahiro Nagano

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut