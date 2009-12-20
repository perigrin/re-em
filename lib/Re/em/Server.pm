package Re::em::Server;
use 5.0100;
our $VERSION = 0.01;
use Moose::Role;
use Try::Tiny;
use Plack::Util;
use HTTP::Parser::XS qw(parse_http_request);
use HTTP::Status;
use HTTP::Date;

use constant REQUEST_INCOMPLETE = -2;
use constant REQUEST_BROKEN     = -1;

requires 'application';

has socket => (
    isa      => 'IO::Socket::UNIX',
    is       => 'ro',
    required => 1,
    handles  => {
        read   => 'read_socket',
        atmark => 'socket_not_atmark',
        print  => 'write_all',
    },

);

has environment => ( isa => 'Hash', is => 'ro', required => 1 );

sub accept {
    my ($self) = @_;
    my $env    = $self->environment;
    my $buf    = '';

    my $res = [ 400, [ 'Content-Type' => 'text/plain' ], ['Bad Request'] ];

    my $data = '';
    io {
        context $server;
        accept {
            again;
              context getline, shift(@_), \( my $buf = '' );
              tail { $data .= $_[0]; again; }
        };
    };
    until ( $self->socket_atmark ) { $buf .= $self->read_socket }

    given ( parse_http_request( $data, $env ) ) {
        when ( $_ > 0 ) {    # handle request

            if ($use_keepalive) {
                if ( my $c = $env->{HTTP_CONNECTION} ) {
                    $use_keepalive = undef unless $c =~ /^\s*keep-alive\s*/i;
                }
                else {
                    $use_keepalive = undef;
                }
            }

            $buf = substr $buf, $_;

            if ( $env->{CONTENT_LENGTH} ) {
                while ( length $buf < $env->{CONTENT_LENGTH} ) {
                    $buf .= $self->read_socket or return;
                }
            }

            open my $input, "<", \$buf;
            $env->{'psgi.input'} = $input;
            $res = Plack::Util::run_app $self->application, $env;

        }
        when ( $_ == REQUEST_INCOMPLETE ) { }
        when ( $_ == REQUEST_BROKEN )     { }
        default { confess "Something horrible happened: $_"; };
    }

    my $conn_value;
    my @lines = (
        "Date: @{[HTTP::Date::time2str()]}\015\012",
        "Server: Re'em/$VERSION\015\012",
    );

    Plack::Util::header_iter(
        $res->[1],
        sub {
            my ( $k, $v ) = @_;
            if ( lc $k eq 'connection' ) {
                $use_keepalive = undef
                  if $use_keepalive && lc $v ne 'keep-alive';
            }
            else {
                push @lines, "$k: $v\015\012";
            }
        }
    );

    $use_keepalive = undef
      if $use_keepalive
          && !Plack::Util::header_exists( $res->[1], 'Content-Length' ) );

    push @lines, "Connection: keep-alive\015\012" if $use_keepalive;

    my $status = HTTP::Status::status_message( $res->[0] );
    unshift @lines, "HTTP/1.0 $res->[0] $status\015\012";
    push @lines, "\015\012";

    $self->write_all( join( '', @lines ) ) or return;

    my $err;
    my $done;
    try {
          Plack::Util::foreach(
              $res->[2],
              sub {
                  $self->write_all( $conn, $_[0], $self->{timeout} )
                    or die "failed to send all data\n";
              },
          );
    }
    catch {
          given ($_) {
              when (qr/^failed to send all data\n/) { return; }
              default                               { confess $err };
          }
    };
    $use_keepalive;
}

1;
__END__
