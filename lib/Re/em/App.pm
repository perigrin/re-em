package Re::em::App;
use Moose;

with qw(Re::em::Server);

has handler => ( isa => 'CodeRef', reader => 'application' );

1;

__END__

=head1 SYNOPSIS

    Re'em::App->new(
        handler => sub {
            return [ '200', [ 'Content-Type' => 'text/plain' ], ["Hello World"], ];
        }
    );

or

    class MyApp extends Re'em::App {
        sub application { 
            return [ '200', [ 'Content-Type' => 'text/plain' ], ["Hello World"], ];
        }
    }

