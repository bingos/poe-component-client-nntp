package POE::Component::Client::NNTP::Constants;

# ABSTRACT: importable constants for POE::Component::Client::NNTP plugins.

use strict;
use warnings;

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

=pod

=head1 SYNOPSIS

  use POE::Component::Client::NNTP::Constants qw(:ALL);

=head1 DESCRIPTION

POE::Component::Client::NNTP::Constants defines a number of constants that are required by the plugin system.

=head1 EXPORTS

=over

=item C<NNTP_EAT_NONE>

Value: 1

=item C<NNTP_EAT_CLIENT>

Value: 2

=item C<NNTP_EAT_PLUGIN>

Value: 3

=item C<NNTP_EAT_ALL>

Value: 4

=back

=head1 SEE ALSO

L<POE::Component::Client::NNTP>

L<POE::Component::Pluggable>

=cut
