#!/usr/bin/perl
#

#############################################################################
#
# Find the beginning of the application by searching for 'MAIN:'
#
#############################################################################

# Always use 'strict' and 'warnings'
use strict;
use warnings;

# Version information
my $ID  = q$Id: update-infoblox-api, v1.0 2010-APR-03 smithdonalde@gmail.com $;
my $REV = q$Version: 1.0 $;

# Look for libraries in a few more places
use FindBin;
BEGIN {
    push (@INC, "./lib");
    push (@INC, "$FindBin::Bin");
    push (@INC, "$FindBin::Bin/lib");
};

# Store the name of the application for later use
my $basename = $FindBin::Script;

# Load libraries for this script
use Archive::Tar;
use Getopt::Long;
use HTTP::Request;
use HTTP::Response;
use HTML::LinkExtor;
use LWP::Simple;
use LWP::UserAgent;
use Pod::Usage;

# Data structure for defaults and config file options
my $config = {
    # standard options
    'grid_master'   => '192.168.1.2',
    'path'          => '/api/dist/CPAN/authors/id/INFOBLOX/',
    'temp_dir'      => '/tmp/',
};


##############################################################################
# Usage         :   process_config_options()
# Purpose       :   Processes command line options and reads in config file
# Returns       :   nothing, modifies global $config variable
# Parameters    :   none
sub process_config_options {
    my $options;

    # Get the passed parameters
    my $options_okay = GetOptions (
        #Standard options for Infoblox Grid Communication
        'server|gmip|s|g:s' => \$config->{'grid_master'},
        'dir:s'         => \$config->{'temp_dir'},

        #Standard meta-options
        'help|?'        => sub { pod2usage(1); },
        'man'           => sub { pod2usage(-exitstatus => 0, -verbose => 2); },
        'version'       => sub { print "\n$ID\n$REV\n\n"; exit; },
    );

    # If we got some option we didn't expect, print a message and abort
    if ( !$options_okay ) {
        print("ERROR :  An invalid option was passed on the command line.\n");
        print("NOTICE:  Try '$basename --help' for help.\n");
        exit 1;
    }

    # Build the rest of the config
    $config->{'url'} = "https://" . $config->{'grid_master'} . $config->{'path'};

    # Print the configuration settings we're using
    foreach my $option_item ( keys %{ $config } ) {
        if ($config->{$option_item}) {
            print("CONFIG:  $option_item = [$config->{$option_item}]\n");
        }
    }
}


##############################################################################
#
# Beginning of the main part of the program
#   Main body is still further down
#
##############################################################################

# Read the command line parameters and config file (data saved in global $config variable)
process_config_options();

##############################################################################
#
# MAIN:
#{

    my $browser = LWP::UserAgent->new();
    $browser->timeout(10);

    my $request = HTTP::Request->new(GET => $config->{'url'});
    my $response = $browser->request($request);
    if ($response->is_error()) {
        printf "ERROR :  %s\n", $response->status_line;
        exit 1;
    };

    # Grab the page that has the link to the API file
    my $contents = $response->content();

    # Pull apart the links in the returned page
    my ($page_parser) = HTML::LinkExtor->new();
    $page_parser->parse($contents)->eof;
    my @links = $page_parser->links;

    # Find the one link that goes to a TAR GZIP file and keep that
    foreach my $link (@links) {
        if ($$link[2] =~ m/^Infoblox.*.tar.gz$/) {
            print "FOUND :  $$link[2]\n";
            $config->{'file'} = $$link[2];
        }
    }

    # Prepare the commands to use
    $config->{'full_path'}      = $config->{'url'} . $config->{'file'};
    $config->{'output_file'}    = $config->{'temp_dir'} . $config->{'file'};
    $config->{'api_dir'}        = $config->{'temp_dir'} . $config->{'file'};
    $config->{'api_dir'}        =~ s/.tar.gz$//;

    $config->{'is_downloaded'} = 0;
    if (-e $config->{'output_file'}) {
        $config->{'is_downloaded'} = 1;
        print "NOTICE:  Skipping download.  File already exists in target location ($config->{'output_file'}).\n";
    } else {
        # Let's go ahead and actually attempt to download the file
        print "NOTICE:  Attempting to download file '$config->{'file'}'\n";
        $request = HTTP::Request->new(GET => $config->{'full_path'});
        $response = $browser->request($request);
        if ($response->is_error()) {
            printf "ERROR :  %s\n", $response->status_line;
            exit 1;
        };

        # Grab the file itself
        $contents = $response->content();

        # Put the file in the target location
        open(my $output_file, '>', $config->{'output_file'})
            or die "ERROR :  Couldn't open file for writing: $!n";
        print $output_file $contents;
        close $output_file;

        if (-e $config->{'output_file'}) {
            $config->{'is_downloaded'} = 1;
            print "NOTICE:  File downloaded to '$config->{'output_file'}'.\n";
        }
    }

    if ($config->{'is_downloaded'}) {
        # Extract the tar file
        $config->{'is_extracted'} = 1;
        if (-e $config->{'api_dir'}) {
            print "NOTICE:  Skipping extraction.  Directory '$config->{'api_dir'}' already exists.\n";
        } else {
            if (! chdir "$config->{'temp_dir'}") {
                $config->{'is_extracted'} = 0;
            } else {
                print "NOTICE:  Attempting to unpack file to '$config->{'api_dir'}'\n";
                my $tarfile = Archive::Tar->new;
                $tarfile->read($config->{'output_file'});
                $tarfile->extract();

                if (-e $config->{'api_dir'}) {
                    print "NOTICE:  File successfully unpacked to '$config->{'api_dir'}'\n";
                } else {
                    print "NOTICE:  Failed to extract file.\n";
                    $config->{'is_extracted'} = 0;
                }
            }
        }
    }

    # Print the instructions on what to do next
    print "ACTION:  Copy and paste the next series of commands into a terminal window.\n";
    if (! $config->{'is_downloaded'}) { printf "  curl --insecure %s > %s\n", $config->{'full_path'}, $config->{'output_file'}; };
    if (! $config->{'is_extracted'}) {
        printf "  cd %s\n", $config->{'temp_dir'};
        printf "  tar xvzf %s\n", $config->{'output_file'};
    }
    printf "  cd %s\n", $config->{'api_dir'};
    print "  perl Makefile.PL\n";
    print "  make\n";
    print "  sudo make install\n";

    exit;
#}


##############################################################################
#
# End of main
#
##############################################################################


__END__



#############################################################################
#
# Documentation (perldoc)
#

=head1 NAME

Update Infoblox API tool

=head1 SYNOPSIS

update-infoblox-api.pl [-s <gm_ip>] [-d <temp_dir>]

See below for more description of the available options.

=head1 DESCRIPTION

This tool is intended to help facilitate downloading and installing the
Infoblox Perl API.  It is intended to figure out what version of the API to
grab from the target Grid Master and then supply the commands necessary to
simply cut and paste into a terminal window.

=head1 OPTIONS

=over

=item   -s <gm_ip>

This is the IP address of the Grid Master.
The default value is "192.168.1.2".

=item   -d <temp_dir>

The directory where you want to download the API tar-gzip file to.  This
defaults to '/tmp/'.  Make sure you end the path with a slash.

=item   --version

Print version information

=item   --help

Print this summary

=item   --man

Displays the complete manpage then exits gracefully.

=back

=head1 COMMON USAGE

update-infoblox-api -s dns5demo.infoblox.com -d /tmp/

    Downloads the API code from the dns5demo appliance and drops it into the
    '/tmp/' directory on the local system.

=head1 REQUIRED ARGUMENTS

All parameters have default values.

=head1 DIAGNOSTICS

Read the output messages.

=head1 DEPENDENCIES

This application uses the following Perl modules.

    Getopt::Long;
    HTTP::Request;
    HTTP::Response;
    HTML::LinkExtor;
    LWP::Simple;
    LWP::UserAgent;
    Pod::Usage;

=head1 AUTHOR

Don Smith (smithdonalde@gmail.com) -- Author and Maintainer

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2010 by Don Smith.  All rights reserved.

Any changes or enhancements to this application should be sent to the
AUTHOR(s).

This application is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

=cut


#############################################################################
#
# Change log
#
# 2010-04-03    :   version 1
#
