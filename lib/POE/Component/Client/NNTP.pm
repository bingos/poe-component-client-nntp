# Author: Chris "BinGOs" Williams
# Derived from some code by Dennis Taylor
#
# This module may be used, modified, and distributed under the same
# terms as Perl itself. Please see the license that came with your Perl
# distribution for details.
#

package POE::Component::Client::NNTP;

use 5.006;
use strict;
use warnings;
use POE qw( Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW
            Filter::Line  );
use Carp;
use Socket;
use base qw(POE::Component::Pluggable);
use POE::Component::Pluggable::Constants qw(:ALL);
use vars qw($VERSION);

$VERSION = '2.10';

sub spawn {
  my ($package,$alias,$hash) = splice @_, 0, 3;
  my $package_events = {};

  $package_events->{$_} = '_accept_input' for qw(article body head stat group help ihave last list newgroups newnews next post quit slave authinfo);

  croak "Not enough parameters to $package::spawn()" unless $alias;
  croak "Second argument to $package::spawn() must be a hash reference" unless ref $hash eq 'HASH';
  
  $hash->{'NNTPServer'} = "news" unless defined $hash->{'NNTPServer'} or defined $ENV{'NNTPSERVER'};
  $hash->{'NNTPServer'} = $ENV{'NNTPSERVER'} unless defined $hash->{'NNTPServer'};
  $hash->{'Port'} = 119 unless defined $hash->{'Port'};
  
  my $self = bless { }, $package;
  
  $self->_pluggable_init( prefix => 'nntp_', types => [ 'NNTPSERVER', 'NNTPCMD' ] );
  $self->{remoteserver} = $hash->{'NNTPServer'};
  $self->{serverport} = $hash->{'Port'};
  $self->{localaddr} = $hash->{'LocalAddr'};

  $self->{session_id} = POE::Session->create(
			object_states => [
                          $self => [ qw(_start _stop _sock_up _sock_down _sock_failed _parseline register unregister shutdown send_cmd connect disconnect send_post __send_event) ],
			  $self => $package_events,
			],
			heap => $self,
                     	args => [ $alias, @_ ],
  )->ID();
  return $self;
}

# Register and unregister to receive events

sub session_id {
  return $_[0]->{session_id};
}

sub connected {
  return $_[0]->{connected};
}

sub register {
  my ($kernel, $self, $session, $sender, @events) =
    @_[KERNEL, OBJECT, SESSION, SENDER, ARG0 .. $#_];

  die "Not enough arguments" unless @events;

  my $sender_id = $sender->ID();
  foreach (@events) {
    $_ = "nntp_" . $_ unless /^_/;
    $self->{events}->{$_}->{$sender_id} = $sender_id;
    $self->{sessions}->{$sender_id}->{'ref'} = $sender_id;
    unless ($self->{sessions}->{$sender_id}->{refcnt}++ or $session == $sender) {
      $kernel->refcount_increment($sender_id, __PACKAGE__ );
    }
  }
  $kernel->post( $sender, 'nntp_registered', $self );
  undef;
}

sub unregister {
  my ($kernel, $self, $session, $sender, @events) =
    @_[KERNEL,  OBJECT, SESSION,  SENDER,  ARG0 .. $#_];

  die "Not enough arguments" unless @events;

  my $sender_id = $sender->ID();
  foreach (@events) {
    delete $self->{events}->{$_}->{$sender_id};
    if (--$self->{sessions}->{$sender_id}->{refcnt} <= 0) {
      delete $self->{sessions}->{$sender_id};
      unless ($session == $sender) {
        $kernel->refcount_decrement($sender_id, __PACKAGE__ );
      }
    }
  }
  undef;
}

sub _unregister_sessions {
  my $self = shift;
  foreach my $session_id ( keys %{ $self->{sessions} } ) {
     my $refcnt = $self->{sessions}->{$session_id}->{refcnt};
     while ( $refcnt --> 0 ) {
	$poe_kernel->refcount_decrement($session_id, __PACKAGE__);
     }
     delete $self->{sessions}->{$session_id};
  }
}

# Session starts or stops

sub _start {
  my ($kernel,$session,$sender,$self,$alias) = @_[KERNEL,SESSION,SENDER,OBJECT,ARG0];
  my @options = @_[ARG1 .. $#_];
  $self->{session_id} = $session->ID();
  $session->option( @options ) if @options;
  $kernel->alias_set($alias);
  if ($kernel != $sender ) {
    my $sender_id = $sender->ID;
    $self->{events}->{'nntp_all'}->{$sender_id} = $sender_id;
    $self->{sessions}->{$sender_id}->{'ref'} = $sender_id;
    $self->{sessions}->{$sender_id}->{refcnt}++;
    $kernel->refcount_increment($sender_id, __PACKAGE__);
    $kernel->post( $sender, 'nntp_registered', $self );
  }
  $self->{connected} = 0;
  undef;
}

sub _stop {
  my ($kernel, $self, $quitmsg) = @_[KERNEL, OBJECT, ARG0];
  $kernel->call( $_[SESSION], 'shutdown', $quitmsg ) if $self->{connected};
  undef;
}

sub connect {
  my ($kernel, $self, $session) = @_[KERNEL, OBJECT, SESSION];

  $kernel->call ($session, 'quit') if $self->{socket};

  $self->{socketfactory} = POE::Wheel::SocketFactory->new(
       SocketDomain => AF_INET,
       SocketType => SOCK_STREAM,
       SocketProtocol => 'tcp',
       RemoteAddress => $self->{'remoteserver'},
       RemotePort => $self->{'serverport'},
       SuccessEvent => '_sock_up',
       FailureEvent => '_sock_failed',
       ( $self->{localaddr} ? (BindAddress => $self->{localaddr}) : () ),
  );
  undef;
}

sub disconnect {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  delete $self->{'socket'};
  undef;
}

# Internal function called when a socket is closed.
sub _sock_down {
  my ($kernel, $self) = @_[KERNEL, OBJECT];

  # Destroy the RW wheel for the socket.
  delete $self->{'socket'};
  $self->{connected} = 0;

  $kernel->post( $_, 'nntp_disconnected', $self->{'remoteserver'} ) 
	for keys %{ $self->{sessions} };
  undef;
}

sub _sock_up {
  my ($kernel,$self,$session,$socket) = @_[KERNEL,OBJECT,SESSION,ARG0];

  delete $self->{socketfactory};

  $self->{localaddr} = (unpack_sockaddr_in( getsockname $socket))[1];

  $self->{'socket'} = new POE::Wheel::ReadWrite
  (
        Handle => $socket,
        Driver => POE::Driver::SysRW->new(),
        Filter => POE::Filter::Line->new( InputLiteral => "\x0D\x0A" ),
        InputEvent => '_parseline',
        ErrorEvent => '_sock_down',
   );

  unless ($self->{'socket'}) {
  $self->_send_event ( 'nntp_socketerr', "Couldn't create ReadWrite wheel for NNTP socket" );
	return;
  }

  $self->{connected} = 1;
  $kernel->post( $_, 'nntp_connected', $self->{remoteserver} ) for keys %{ $self->{sessions} };
  undef;
}

sub _sock_failed {
  my ($kernel, $self, $op, $errno, $errstr) = @_[KERNEL, OBJECT, ARG0..ARG2];
  $self->_send_event( 'nntp_socketerr', "$op error $errno: $errstr" );
  undef;
}

# Parse each line from received at the socket

sub _parseline {
  my ($kernel, $session, $self, $line) = @_[KERNEL, SESSION, OBJECT, ARG0];

  SWITCH: {
    if ( $line =~ /^\.$/ and defined $self->{current_event} ) {
      $self->_send_event( 'nntp_' . shift( @{ $self->{current_event} } ), @{ $self->{current_event} }, $self->{current_text} );
      delete $self->{current_event};
      delete $self->{current_text};
      last SWITCH;
    }
    if ( $line =~ /^([0-9]{3}) +(.+)$/ and !defined $self->{current_event} ) {
      my $current_event = [ $1, $2 ];
      if ( $1 =~ /(220|221|222|100|215|231|230)/ ) {
        $self->{current_event} = $current_event;
        $self->{current_text} = [ ];
      } 
      else {
	$self->_send_event( 'nntp_' . $1, $2 );
      }
      last SWITCH;
    }
    if ( defined $self->{current_event} ) {
      push @{ $self->{current_text} }, $line;
      last SWITCH;
    }
  }
  undef;
}

sub _pluggable_event {
  my $self = shift;
  $poe_kernel->call( $self->{session_id}, '__send_event', @_ );
  return 1;
}

sub __send_event {
  my ($kernel,$self,$event,@args) = @_[KERNEL,OBJECT,ARG0,ARG1..$#_];
  $self->_send_event( $event, @args );
  return;
}

# Sends an event to all interested sessions. This is a separate sub
# because I do it so much, but it's not an actual POE event because it
# doesn't need to be one and I don't need the overhead.

sub _send_event  {
  my ($self, $event, @args) = @_;

  my @extra_args;
  return 1 if $self->_pluggable_process( 'NNTPSERVER', $event, \( @args ), \@extra_args ) == PLUGIN_EAT_ALL;
  push @args, @extra_args if scalar @extra_args;

  my %sessions;

  foreach (values %{$self->{events}->{'nntp_all'}},
           values %{$self->{events}->{$event}}) {
    $sessions{$_} = $_;
  }
  $poe_kernel->post( $_, $event, @args ) for values %sessions;
}

sub shutdown {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  $self->_unregister_sessions();
  $kernel->alarm_remove_all();
  $kernel->alias_remove($_) for $kernel->alias_list();
  delete $self->{$_} for qw(socket sock socketfactory dcc wheelmap);
  $self->_pluggable_destroy();
  undef;
}

sub send_cmd {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my $arg = join ' ', @_[ARG0 .. $#_];
  return 1 if $self->_pluggable_process( 'NNTPCMD', 'send_cmd', \$arg ) == PLUGIN_EAT_ALL;
  $self->{socket}->put($arg) if defined $self->{socket};
  undef;
}

sub _accept_input {
  my ($kernel,$self,$state) = @_[KERNEL,OBJECT,STATE];
  my $arg = join ' ', @_[ARG0 .. $#_];
  return 1 if $self->_pluggable_process( 'NNTPCMD', $state, \$arg ) == PLUGIN_EAT_ALL;
  $self->{socket}->put("$state $arg") if defined $self->{socket};
  undef;
}

sub send_post {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  croak "Argument to send_post must be an array ref" unless ref $_[ARG0] eq 'ARRAY';
  return unless defined $self->{socket};
  $self->{socket}->put($_) for @{ $_[ARG0] };
  $self->{socket}->put('.');
  undef;
}

1;
__END__

=head1 NAME

POE::Component::Client::NNTP - A POE component that implements an RFC 977 NNTP client.

=head1 SYNOPSIS

   # Connects to NNTP Server, selects a group, then downloads all current articles.
   use strict;
   use POE;
   use POE::Component::Client::NNTP;
   use Mail::Internet;
   use FileHandle;

   $|=1;

   my $nntp = POE::Component::Client::NNTP->spawn ( 'NNTP-Client', { NNTPServer => 'news.host' } );

   POE::Session->create(
	package_states => [
		'main' => { nntp_disconnected => '_shutdown',
			    nntp_socketerr    => '_shutdown',
			    nntp_421          => '_shutdown',
			    nntp_200	      => '_connected',
			    nntp_201	      => '_connected',
		},
		'main' => [ qw(_start nntp_211 nntp_220 nntp_223 nntp_registered)
		],
	],
   );

   $poe_kernel->run();
   exit 0;

   sub _start {
	my ($kernel,$heap) = @_[KERNEL,HEAP];
	
	# Our session starts, register to receive all events from poco-client-nntp
	$kernel->post ( 'NNTP-Client' => register => 'all' );
	# Okay, ask it to connect to the server
	$kernel->post ( 'NNTP-Client' => 'connect' );
	undef;
   }

   sub nntp_registered {
	my $nntp_object = $_[ARG0];
	undef;
   }

   sub _connected {
	my ($kernel,$heap,$text) = @_[KERNEL,HEAP,ARG0];

	print "$text\n";

	# Select a group to download from.
	$kernel->post( 'NNTP-Client' => group => 'random.group' );
	undef;
   }

   sub nntp_211 {
	my ($kernel,$heap,$text) = @_[KERNEL,HEAP,ARG0];
	print "$text\n";

	# The NNTP server sets 'current article pointer' to first article in the group.
	# Retrieve the first article
	$kernel->post( 'NNTP-Client' => 'article' );
	undef;
   }

   sub nntp_220 {
	my ($kernel,$heap,$text,$article) = @_[KERNEL,HEAP,ARG0,ARG1];
	print "$text\n";

	my $message = Mail::Internet->new( $article );
	my $filename = $message->head->get( 'Message-ID' );
	my $fh = new FileHandle "> articles/$filename";
	$message->print( $fh );
	$fh->close;

	# Set 'current article pointer' to the 'next' article in the group.
	$kernel->post( 'NNTP-Client' => 'next' );
	undef;
   }

   sub nntp_223 {
	my ($kernel,$heap,$text) = @_[KERNEL,HEAP,ARG0];
	print "$text\n";

	# Server has moved to 'next' article. Retrieve it.
	# If there isn't a 'next' article an 'nntp_421' is generated
	# which will call '_shutdown'
	$kernel->post( 'NNTP-Client' => 'article' );
	undef;
   }

   sub _shutdown {
	my ($kernel,$heap) = @_[KERNEL,HEAP];

	# We got disconnected or a socketerr unregister and terminate the component.
	$kernel->post ( 'NNTP-Client' => unregister => 'all' );
	$kernel->post ( 'NNTP-Client' => 'shutdown' );
	undef;
   }


=head1 DESCRIPTION

POE::Component::Client::NNTP is a POE component that provides non-blocking NNTP access to other
components and sessions. NNTP is described in RFC 977 L<http://www.faqs.org/rfcs/rfc977.html>, 
please read it before doing anything else.

In your component or session, you spawn a NNTP client component, assign it an alias, and then 
send it a 'register' event to start receiving responses from the component.

The component takes commands in the form of events and returns the salient responses from the NNTP
server.

=head1 CONSTRUCTOR

=over

=item spawn

Takes two arguments, a kernel alias to christen the new component with and a hashref. 

Possible values for the hashref are:

   'NNTPServer', the DNS name or IP address of the NNTP host to connect to; 
   'Port', the IP port on that host
   'LocalAddr', an IP address on the client to connect from. 

If 'NNTPServer' is not specified, the default is 'news', unless the environment variable 'NNTPServer' is set. If 'Port' is not specified the default is 119.

  POE::Component::Client::NNTP->spawn( 'NNTP-Client', { NNTPServer => 'news', Port => 119,
		LocalAddr => '192.168.1.99' } );

=back

=head1 METHODS

=over

=item session_id

Returns the session ID of the component's POE::Session.

=item connected

Indicates true or false as to whether the component is currently connected to a server or not.

=back

=head1 INPUT

The component accepts the following events:

=over

=item register

Takes N arguments: a list of event names that your session wants to listen for, minus the 'nntp_' prefix, ( this is 
similar to L<POE::Component::IRC> ). 

Registering for 'all' will cause it to send all NNTP-related events to you; this is the easiest way to handle it.

=item unregister

Takes N arguments: a list of event names which you don't want to receive. If you've previously done a 'register' for a particular event which you no longer care about, this event will tell the NNTP connection to stop sending them to you. (If you haven't, it just ignores you. No big deal).

Please ensure that you always 'unregister' with the component before asking it to 'shutdown'.

=item connect

Takes no arguments. Tells the NNTP component to start up a connection to the previously specified NNTP server. You will 
receive a 'nntp_connected' event.

=item disconnect

Takes no arguments. Terminates the socket connection ungracelessly.

=item shutdown

Takes no arguments. Terminates the component.

Always ensure that you call 'unregister' before shutting down the component.

=back

The following are implemented NNTP commands, check RFC 977 L<http://www.faqs.org/rfcs/rfc977.html> for the arguments accepted by each. Arguments can be passed as a single scalar or a list of arguments:

=over

=item article

Takes either a valid message-ID or a numeric-ID.

=item body

Takes either a valid message-ID or a numeric-ID.

=item head

Takes either a valid message-ID or a numeric-ID.

=item stat

Takes either a valid message-ID or a numeric-ID.

=item group

Takes the name of a newsgroup to select.

=item help

Takes no arguments.

=item ihave

Takes one argument, a message-ID.

=item last

Takes no arguments.

=item list

Takes no arguments.

=item newgroups

Can take up to four arguments: a date, a time, optionally you can specify GMT and an optional list of distributions.

=item newnews

Can take up to five arguments: a newsgroup, a date, a time, optionally you can specify GMT and an optional list of distributions.

=item next

Takes no arguments.

=item post

Takes no arguments. Once you have sent this expect to receive an 'nntp_340' event. When you receive this send the component a 'send_post' event, see below.

=item send_post

Takes one argument, an array ref containing the message to be posted, one line of the message to each array element.

=item quit

Takes no arguments.

=item slave

Takes no arguments.

=item authinfo

Takes two arguments: first argument is either 'user' or 'pass', second argument is the user or password, respectively. 
Not technically part of RFC 977 L<http://www.faqs.org/rfcs/rfc977.html>, but covered in RFC 2980 L<http://www.faqs.org/rfcs/rfc2980.html>.

=item send_cmd

The catch-all event :) Anything sent to this is passed directly to the NNTP server. Use this to implement any non-RFC 
commands that you want, or to completely bypass all the above if you so desire.

=back

=head1 OUTPUT

The following events are generated by the component:

=over

=item nntp_registered

Generated when you either explicitly 'register' with the component or you spawn a NNTP poco
from within your own session. ARG0 is the poco's object.

=item nntp_connected

Generated when the component successfully makes a connection to the NNTP server. Please note, that this is only the
underlying network connection. Wait for either an 'nntp_200' or 'nntp_201' before sending any commands to the server.

=item nntp_disconnected

Generated when the link to the NNTP server is dropped for whatever reason.

=item nntp_socketerr

Generated when the component fails to establish a connection to the NNTP server.

=item Numeric responses ( See RFC 977 )

Messages generated by NNTP servers consist of a numeric code and a text response. These will be sent to you as 
events with the numeric code prefixed with 'nntp_'. ARG0 is the text response.

Certain responses return following text, such as the ARTICLE command, which returns the specified article. These responses
are returned in an array ref contained in ARG1.

Eg. 

  $kernel->post( 'NNTP-Client' => article => $article_num );

  sub nntp_220 {
    my ($kernel,$heap,$text,$article) = @_[KERNEL,HEAP,ARG0,ARG1];

    print "$text\n";
    if ( scalar @{ $article } > 0 ) {
	foreach my $line ( @{ $article } ) {
	   print STDOUT $line;
	}
    }
    undef;
  }

Possible nntp_ values are:

   100 help text follows
   199 debug output

   200 server ready - posting allowed
   201 server ready - no posting allowed
   202 slave status noted
   205 closing connection - goodbye!
   211 n f l s group selected
   215 list of newsgroups follows
   220 n <a> article retrieved - head and body follow 221 n <a> article
   retrieved - head follows
   222 n <a> article retrieved - body follows
   223 n <a> article retrieved - request text separately 230 list of new
   articles by message-id follows
   231 list of new newsgroups follows
   235 article transferred ok
   240 article posted ok

   335 send article to be transferred.  End with <CR-LF>.<CR-LF>
   340 send article to be posted. End with <CR-LF>.<CR-LF>

   400 service discontinued
   411 no such news group
   412 no newsgroup has been selected
   420 no current article has been selected
   421 no next article in this group
   422 no previous article in this group
   423 no such article number in this group
   430 no such article found
   435 article not wanted - do not send it
   436 transfer failed - try again later
   437 article rejected - do not try again.
   440 posting not allowed
   441 posting failed

   500 command not recognized
   501 command syntax error
   502 access restriction or permission denied
   503 program fault - command not performed

=back

=head1 PLUGINS

POE::Component::Client::NNTP now utilises L<POE::Component::Pluggable> to enable a
L<POE::Component::IRC> type plugin system. 

=head2 PLUGIN HANDLER TYPES

There are two types of handlers that can registered for by plugins, these are 

=over

=item NNTPSERVER

These are the 'nntp_' prefixed events that are generated. In a handler arguments are
passed as scalar refs so that you may mangle the values if required.

=item NNTPCMD

These are generated whenever an nntp command is sent to the component. Again, any 
arguments passed are scalar refs for manglement.

=back

=head2 PLUGIN EXIT CODES

Plugin handlers should return a particular value depending on what action they wish
to happen to the event. These values are available as constants which you can use 
with the following line:

  use POE::Component::Client::NNTP::Constants qw(:ALL);

The return values have the following significance:

=over 

=item NNTP_EAT_NONE

This means the event will continue to be processed by remaining plugins and
finally, sent to interested sessions that registered for it.

=item NNTP_EAT_CLIENT

This means the event will continue to be processed by remaining plugins but
it will not be sent to any sessions that registered for it. This means nothing
will be sent out on the wire if it was an NNTPCMD event, beware!

=item NNTP_EAT_PLUGIN

This means the event will not be processed by remaining plugins, it will go
straight to interested sessions.

=item NNTP_EAT_ALL

This means the event will be completely discarded, no plugin or session will see it. This
means nothing will be sent out on the wire if it was an NNTPCMD event, beware!

=back

=head2 PLUGIN METHODS

The following methods are available:

=over

=item pipeline

Returns the L<POE::Component::Pluggable::Pipeline> object.

=item plugin_add

Accepts two arguments:

  The alias for the plugin
  The actual plugin object

The alias is there for the user to refer to it, as it is possible to have multiple
plugins of the same kind active in one POE::Component::Client::NNTP object.

This method goes through the pipeline's push() method.

 This method will call $plugin->plugin_register( $nntp )

Returns the number of plugins now in the pipeline if plugin was initialized, undef
if not.

=item plugin_del

Accepts one argument:

  The alias for the plugin or the plugin object itself

This method goes through the pipeline's remove() method.

This method will call $plugin->plugin_unregister( $irc )

Returns the plugin object if the plugin was removed, undef if not.

=item plugin_get

Accepts one argument:

  The alias for the plugin

This method goes through the pipeline's get() method.

Returns the plugin object if it was found, undef if not.

=item plugin_list

Has no arguments.

Returns a hashref of plugin objects, keyed on alias, or an empty list if there are no
plugins loaded.

=item plugin_order

Has no arguments.

Returns an arrayref of plugin objects, in the order which they are encountered in the
pipeline.

=item plugin_register

Accepts the following arguments:

  The plugin object
  The type of the hook, NNTPSERVER or NNTPCMD
  The event name(s) to watch

The event names can be as many as possible, or an arrayref. They correspond
to the prefixed events and naturally, arbitrary events too.

You do not need to supply events with the prefix in front of them, just the names.

It is possible to register for all events by specifying 'all' as an event.

Returns 1 if everything checked out fine, undef if something's seriously wrong

=item plugin_unregister

Accepts the following arguments:

  The plugin object
  The type of the hook, NNTPSERVER or NNTPCMD
  The event name(s) to unwatch

The event names can be as many as possible, or an arrayref. They correspond
to the prefixed events and naturally, arbitrary events too.

You do not need to supply events with the prefix in front of them, just the names.

It is possible to register for all events by specifying 'all' as an event.

Returns 1 if all the event name(s) was unregistered, undef if some was not found.

=back

=head2 PLUGIN TEMPLATE

The basic anatomy of a plugin is:

        package Plugin;

        # Import the constants, of course you could provide your own 
        # constants as long as they map correctly.
        use POE::Component::NNTP::Constants qw( :ALL );

        # Our constructor
        sub new {
                ...
        }

        # Required entry point for plugins
        sub plugin_register {
                my( $self, $nntp ) = @_;

                # Register events we are interested in
                $nntp->plugin_register( $self, 'NNTPSERVER', qw(all) );

                # Return success
                return 1;
        }

        # Required exit point for pluggable
        sub plugin_unregister {
                my( $self, $nntp ) = @_;

                # Pluggable will automatically unregister events for the plugin

                # Do some cleanup...

                # Return success
                return 1;
        }

        sub _default {
                my( $self, $nntp, $event ) = splice @_, 0, 3;

                print "Default called for $event\n";

                # Return an exit code
                return NNTP_EAT_NONE;
        }

=head1 CAVEATS

The group event sets the current working group on the server end. If you want to use group and numeric form of article|head|etc then you will have to spawn multiple instances of the component for each group you want to access concurrently.

=head1 AUTHOR

Chris Williams, E<lt>chris@bingosnet.co.uk<gt>

With code derived from L<POE::Component::IRC> by Dennis Taylor.

=head1 LICENSE

Copyright C<(c)> Chris Williams and Dennis Taylor.

This module may be used, modified, and distributed under the same terms as Perl itself. Please see the license that came with your Perl distribution for details.

=head1 SEE ALSO

RFC 977  L<http://www.faqs.org/rfcs/rfc977.html>

RFC 2980 L<http://www.faqs.org/rfcs/rfc2980.html>

L<POE::Component::Pluggable>

=cut
