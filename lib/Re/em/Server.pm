package Re::em::Server;
use 5.0100;
use Moose;
use namespace::autoclean;

our $VERSION = 0.01;

use IO::Socket;
use Plack::Util;
use HTTP::Parser::XS qw(parse_http_request);
use HTTP::Status;
use HTTP::Date;

use constant REQUEST_INCOMPLETE => -2;
use constant REQUEST_BROKEN     => -1;
use constant MAX_REQUEST_SIZE   => 131072;

has port => ( isa => 'Int', is => 'ro', );
has host => ( isa => 'Str', is => 'ro', default => `hostname` );

has socket => (
    isa     => 'IO::Socket',
    is      => 'ro',
    builder => 'build_socket',
    handles => { socket_accept => 'accept' },
);

sub build_socket {
    my ($self) = @_;

    IO::Socket::INET->new(
        LocalPort => $self->port,
        Listen    => 5,
    ) or confess $@;

    #   IO::Socket::UNIX->new( Local => "/tmp/$0.sock", Listen => 5 );
}

has environment => ( isa => 'HashRef', is => 'ro', lazy_build => 1 );

sub _build_environment {
    my $self = shift;
    {
        SERVER_PORT         => $self->port,
        SERVER_NAME         => $self->host,
        SCRIPT_NAME         => $0,
        'psgi.version'      => [ 1, 0 ],
        'psgi.errors'       => *STDERR,
        'psgi.url_scheme'   => 'http',
        'psgi.run_once'     => Plack::Util::FALSE,
        'psgi.multithread'  => Plack::Util::FALSE,
        'psgi.multiprocess' => Plack::Util::FALSE,
    };

}

has application => ( isa => 'CodeRef', is => 'rw', lazy_build => 1 );

sub _build_application {
    return sub {
        my $env = shift;
        return [
            '200',
            [ 'Content-Type' => 'text/plain' ],
            ["Hello World"],    # or IO::Handle-like object
        ];
      }
}

sub run {
    my ( $self, $app ) = @_;
    $self->application($app);
    $self->accept();
    $self->clear_application;
}

sub accept {
    my ($self) = @_;
    while (1) {
        if ( my $client = $self->socket_accept ) {
            sysread( $client, ( my $data = '' ), MAX_REQUEST_SIZE );
            my $env = $self->environment;
            my $app = $self->application;
            given ( parse_http_request( $data, $env ) ) {
                when ( $_ > 0 ) {
                    $env->{REMOTE_ADDR} = $client->peerhost;
                    open my $input, "<", \$data;
                    $env->{'psgi.input'} = $input;
                    $self->handle_request( $client, $env, $app ) or last;
                }
                when (REQUEST_BROKEN)     { }
                when (REQUEST_INCOMPLETE) { }
            }
            close $client;
            $self->clear_environment;
        }
    }
}

sub handle_request {
    my ( $self, $client, $env, $app ) = @_;

    my $res = [ 400, [ 'Content-Type' => 'text/plain' ], ['Bad Request'] ];
    $res = Plack::Util::run_app $app, $env;

    my $status  = HTTP::Status::status_message( $res->[0] );
    my $date    = HTTP::Date::time2str();
    my $headers = join '',
      (
        "HTTP/1.1 $res->[0] $status\015\012",
        "Date: $date\015\012",
        "Server: Re'em/$VERSION\015\012",
      );

    Plack::Util::header_iter( $res->[1],
        sub { $headers .= "$_[0]: $_[1]\015\012" } );

    print $client "$headers\015\012";
    my $done;
    try {
        Plack::Util::foreach( $res->[2],
            sub { print $client $_[0] or die "failed to send all data\n" },
        );
        $done = 1;
    }
    catch {
        when (qr/^failed  to send all data\n/) { return; }
        default { confess $_ unless $done };
    };
    return 1;
}

__PACKAGE__->meta->make_immutable;
1;
__END__
