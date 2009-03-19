package POE::Component::Client::NNTP::Constants;

use strict;
use warnings;
use vars qw($VERSION);

$VERSION = '0.02';

require Exporter;
our @ISA = qw( Exporter );
our %EXPORT_TAGS = ( 'ALL' => [ qw( NNTP_EAT_NONE NNTP_EAT_CLIENT NNTP_EAT_PLUGIN NNTP_EAT_ALL ) ] );
Exporter::export_ok_tags( 'ALL' );

# Our constants
sub NNTP_EAT_NONE	() { 1 }
sub NNTP_EAT_CLIENT	() { 2 }
sub NNTP_EAT_PLUGIN	() { 3 }
sub NNTP_EAT_ALL	() { 4 }

1;
__END__

=head1 NAME

POE::Component::Client::NNTP::Constants - importable constants for POE::Component::Client::NNTP plugins.

=head1 SYNOPSIS

  use POE::Component::Client::NNTP::Constants qw(:ALL);

=head1 DESCRIPTION

POE::Component::Client::NNTP::Constants defines a number of constants that are required by the plugin system.

=head1 EXPORTS

=over

=item NNTP_EAT_NONE

Value: 1

=item NNTP_EAT_CLIENT

Value: 2

=item NNTP_EAT_PLUGIN

Value: 3

=item NNTP_EAT_ALL

Value: 4

=back

=head1 MAINTAINER

Chris 'BinGOs' Williams <chris@bingosnet.co.uk>

=head1 LICENSE

Copyright C<(c)> Chris Williams.

This module may be used, modified, and distributed under the same terms as Perl itself. Please see the license that came with your Perl distribution for details.

=head1 SEE ALSO

L<POE::Component::Client::NNTP>

L<POE::Component::Pluggable>

