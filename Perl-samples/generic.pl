#!/usr/local/bin/perl
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
my $ID  = q$Id: generic, v1.02 2011-02-11 don@infoblox.com $;
my $REV = q$Version: 1.02 $;

# Look for libraries in a few more places
use FindBin;
BEGIN {
    push (@INC, "./lib");
    push (@INC, "$FindBin::Bin");
    push (@INC, "$FindBin::Bin/lib");
};

# Store the name of the application for later use
my $basename = $FindBin::Script;

# Add the necessary modules to make this work.
use Carp;
use Cwd;
use File::Copy;             # for copy/move
use File::Path;             # for create_dir
use Getopt::Long;           # for processing command line parameters
use Pod::Usage;             # for built-in help display
use Readonly;               # v1.03 or newer
use Text::CSV;              # for use to write files
use Text::CSV_XS;           # for use to read files

use MLDBM;                  # for use to read files using tie (dbm_read)
use Fcntl;                  # for use to read files using tie (dbm_read)

use Infoblox;               # for use with Infoblox appliances

# Set up debugging levels
Readonly my $DEBUG_ERROR                => 0;
Readonly my $DEBUG_WARNING              => 1;
Readonly my $DEBUG_PROGRESS_INDICATOR   => 2;
Readonly my $DEBUG_INFO                 => 3;
Readonly my $DEBUG_WRITE_FILE           => 4;
Readonly my $DEBUG_WRITE_LINE           => 5;
Readonly my $DEBUG_READ_LINE            => 6;
Readonly my $DEBUG                      => 99;


# Set up readonly and global values
Readonly my $COMMENT_CHAR               =>  q{[#;]};
Readonly my $EMPTY_STRING               =>  q{};
Readonly my $ESCAPE_CHARACTER           =>  q{^};
Readonly my $LEADING_WHITESPACE         => qr{\A \s*}xms;
Readonly my $QUOTE_CHAR                 =>  q{"};
Readonly my $SURROUNDING_WHITESPACE     => qr{\A \s* | \s* \z}xms;
Readonly my $TRAILING_WHITESPACE        => qr{\s* \z}xms;
Readonly my $PROGRESS_INDICATOR         => 2500;
Readonly my $LOGFILENAME                => get_log_filename();

# Data structure for defaults and config file options
my $config = {
    # Infoblox API common settings
    'grid_master'       => '192.168.1.2',
    'username'          => 'admin',
    'password'          => 'infoblox',

    # input and output directories
    #'source_directory'  => cwd() . '/export',
    #'target_directory'  => cwd() . '/output',

    # standard options
    'debug'             => 0,
    'conf_section'      => $EMPTY_STRING,
    'log_to_file'       => 0,
};


#############################################################################
#
# Generic functions -- no specific tie to the tasks in this script
#
#############################################################################

# Usage         :   convert_bits_to_mask($subnet_bits)
# Usage         :   convert_ip_to_number($ip_addr)
# Usage         :   convert_mask_to_bits($subnet_mask)
# Usage         :   convert_number_to_ip($ip_value)
# Usage         :   count_lines($filename)
# Usage         :   create_dir($directory)
# Usage         :   create_file($filename, $text_data)
# Usage         :   csv_to_hash($filename, [$key_column])
# Usage         :   dbm_read($filename, [$key_column])
# Usage         :   debug_log($label, [$ref,] @message)
# Usage         :   debug_print($level, $label, [$ref,] @message)
# Usage         :   decimal2mac($mac_address)
# Usage         :   display_progress($debug_level, $current_record, $total_records)
# Usage         :   error_print($message, [$label])
# Usage         :   get_log_filename()
# Usage         :   is_array(x)
# Usage         :   is_hash(x)
# Usage         :   is_numeric(x)
# Usage         :   make_list_unique($array_ref, $separator)
# Usage         :   quit($message)
# Usage         :   read_config($filename, $section, $config_record)
# Usage         :   write_csvfile($filename, $fields_to_write, $hash_ref)
# Usage         :   ltrim($string)
# Usage         :   rtrim($string)
# Usage         :   trim($string)


##############################################################################
# Usage         :   convert_bits_to_mask($subnet_bits)
# Purpose       :   Return the dotted decimal form of a mask from the number
#                       of bits (0-32)
# Returns       :   A scalar dotted decimal mask
# Parameters    :   The number of bits in the mask
sub convert_bits_to_mask {
    my ($bits) = @_;

    my %clook = (
        # Standard classful masks
        0  => '0' ,
        1  => '128.0.0.0',  9  => '255.128.0.0',  17 => '255.255.128.0',
        2  => '192.0.0.0',  10 => '255.192.0.0',  18 => '255.255.192.0',
        3  => '224.0.0.0',  11 => '255.224.0.0',  19 => '255.255.224.0',
        4  => '240.0.0.0',  12 => '255.240.0.0',  20 => '255.255.240.0',
        5  => '248.0.0.0',  13 => '255.248.0.0',  21 => '255.255.248.0',
        6  => '252.0.0.0',  14 => '255.252.0.0',  22 => '255.255.252.0',
        7  => '254.0.0.0',  15 => '255.254.0.0',  23 => '255.255.254.0',
        8  => '255.0.0.0',  16 => '255.255.0.0',  24 => '255.255.255.0',

        # Classless masks
        25 => '255.255.255.128',
        26 => '255.255.255.192',
        27 => '255.255.255.224',
        28 => '255.255.255.240',
        29 => '255.255.255.248',
        30 => '255.255.255.252',
        31 => '255.255.255.254',
        32 => '255.255.255.255',
    );

    return ( $clook{$bits} ) ;
}

##############################################################################
# Usage         :   convert_ip_to_number($ip_addr)
# Purpose       :   Return the IP value of an IP address
# Returns       :   An integer
# Parameters    :   An IP address
sub convert_ip_to_number {
    my ($ip_addr) = @_;
    Readonly my $VALID_IPADDRESS_FORMAT => qr{^\b((([01]?\d{1,2}|2([0-4]\d|5[0-5]))\.){3}([01]?\d{1,2}|2([0-4]\d|5[0-5])))\b$}xms;

    # Make sure the IP address is valid
    if ($ip_addr !~ $VALID_IPADDRESS_FORMAT) {
        debug_print($DEBUG_INFO, "DEBUG", "convert_ip_to_number: IP address does not match a valid format - $ip_addr");
        return;
    }

    my @octets = split(/\./, $ip_addr);

    my $ip_value
        = (2 ** 24) * $octets[0]
        + (2 ** 16) * $octets[1]
        + (2 **  8) * $octets[2]
        +             $octets[3];

    return ( $ip_value ) ;
}

##############################################################################
# Usage         :   convert_mask_to_bits($subnet_mask)
# Purpose       :   Return the dotted decimal form of a mask from the number
#                       of bits (0-32)
# Returns       :   A scalar dotted decimal mask
# Parameters    :   The number of bits in the mask
sub convert_mask_to_bits {
    my ($mask) = @_;

    # Define a hash of octet values to bits
    my %mask_lookup = (
        0   => 0,
        128 => 1,   192 => 2,   224 => 3,   240 => 4,
        248 => 5,   252 => 6,   254 => 7,   255 => 8,
    );

    # Split the mask into four octets
    my @octets = split(/\./, $mask);

    # Define the variable to store the bits
    my $bits = 0;

    # For each octet, add the appropriate bits
    foreach my $octet (@octets) {
        $bits += $mask_lookup{$octet};
    }

    return ( $bits ) ;
}

##############################################################################
# Usage         :   convert_number_to_ip($ip_value)
# Purpose       :   Return the dotted decimal form of an IP address from an
#                       IP value
# Returns       :   A scalar dotted decimal IP address
# Parameters    :   An integer
sub convert_number_to_ip {
    my ($ip_value) = @_;
    my ($octet1, $octet2, $octet3, $remainder);

    $octet1      = int($ip_value  / (2 ** 24));
    $remainder   = $ip_value      % (2 ** 24);

    $octet2      = int($remainder / (2 ** 16));
    $remainder   = $ip_value      % (2 ** 16);

    $octet3      = int($remainder / (2 ** 8));
    $remainder   = $ip_value      % (2 ** 8);

    # Address any signed integer problems
    if ($octet1 < 0) {
        $octet1 += 255;
    }

    my $ip_addr     = "$octet1.$octet2.$octet3.$remainder";

    return ( $ip_addr ) ;
}

##############################################################################
# Usage         :   count_lines($filename)
# Purpose       :   Counts the number of lines in a file
# Returns       :   The total lines in the file
# Parameters    :   The name of the file
sub count_lines {
    # If there is a list of files, we'll keep a line count for each
    my ($filename) = @_;
    my $num_lines   = 0;

    # Make sure the file exists before we open it
    if (-e $filename) {
        # Open the file for reading and count the lines
        open (my $fh, "<", $filename)
            or next COUNT_LOOP;

        while (<$fh>) {
            $num_lines++;
        }

        close $fh;
    }

    debug_print($DEBUG, "DEBUG", "count_lines: Counted $num_lines in file '$filename'");

    # Return both the total number of lines
    return ($num_lines);
}

##############################################################################
# Usage         :   create_dir($directory)
# Purpose       :   Creates a directory if it does not exist
# Returns       :   1 on success, 0 on failure
# Parameters    :   Takes a path
sub create_dir {
    my ($directory) = @_;

    if ( !(-d $directory) ) {
        my $error = mkpath $directory;
        my $reason = $!;

        # if the directory doesn't exist, we probably don't have permissions
        if (! (-d $directory)) {
            error_print("Failed to create directory [$directory] mkpath error is [$error/$reason]");
            return 0;
        }
        else {
            debug_print($DEBUG_INFO, $EMPTY_STRING, "created directory [$directory]");
        }
    }
    else {
        debug_print($DEBUG_INFO, $EMPTY_STRING, "directory [$directory] already exists");
    }

    return 1;
}

##############################################################################
# Usage         :   create_file($filename, $text_data)
# Purpose       :   Create a new file containing data
# Returns       :   Nothing
# Parameters    :   filename to create
#                   data to write in the file (such as a header row)
sub create_file {
    my ($filename, $text_data) = @_;

    debug_print($DEBUG_INFO, "FILE", "\tCreating file [$filename]");
    open my $fh, '>', $filename
        or quit("FATAL :  Unable to open [$filename] for writing");
    print $fh "$text_data";

    close $fh
        or error_print("Unable to close [$filename] after writing");

    return;
}

##############################################################################
# Usage         :   csv_to_hash($filename, [$key_column])
# Purpose       :   Reads in the passed CSV and returns a hash of the data
# Returns       :   A hash of the data, the key is the first column or
#                   the optional $key_column
# Parameters    :   $filename of file to read
#                   optional $key_column
# Example       :   csv_to_hash("data.csv")
sub csv_to_hash {
    my ($filename, $key_column) = @_;

    # If the file doesn't exist or is empty, print an error message and return
    if (-z $filename) {
        debug_print($DEBUG_WARNING, "NOTICE", "File [$filename] is empty.");
        return;
    }

    debug_print($DEBUG_INFO, "FILE", "reading from file [$filename]");

    # Define some local variables
    my $total_lines = count_lines($filename);   # Get the total number of lines in the file
    my $line_no     = 0;                        # Create a variable to help us keep track of progress
    my $bad_records = 0;                        # Keep track of how many records are rejected
    my @field_list;                             # Create a variable to hold the field names
    my $record;                                 # Temporary data structure
    my %csv_hash;                               # Define the hash where we will store the data we read

    # We need to create an object to read the file
    my $csv = Text::CSV_XS->new({
        sep_char            =>  q{,},   # Field are comma separated
        escape_char         =>  q{`},   # Backticks are always data
        quote_char          =>  q{"},   # Quotes allowed
        binary              =>  0,      # Read in text mode
        allow_loose_quotes  =>  1,      # Allow --> data,data,some "more" data,data
    });

    # Open the file for reading
    open (my $csv_fh, "<", $filename)
        or quit("FATAL :  Unable to open [$filename] for reading.");

    # Read the file line-by-line
    CSV_LOOP:
    while (my $line = <$csv_fh>) {
        chomp($line);                   # Remove CRLF
        $line =~ s/\r//g;               # Remove CR because chomp on CYGWIN won't
        $line_no++;

        # The following two regular expressions resolve a QIP CSV issue
        $line =~ s/`/$ESCAPE_CHARACTER/g;   # Immunize against use of escape character
        $line =~ s/""""/`"`"/g;         # Special case double-double 'inside' qoutes
        $line =~ s/"""/"/g;             # Do this first to replace 'outside' quotes
        $line =~ s/""/`"/g;             # Then do this for any 'inside' quotes

        # Check for a blank line
        if (length($line) == 0) {
            next CSV_LOOP;
        }

        # Process the current line
        if (! $csv->parse($line)) {
            debug_print($DEBUG_WARNING, "REJECT", "Bad data [$line]");
            my $err = $csv->error_input;
            debug_print($DEBUG_WARNING, "ERROR", "csv->parse() failed on argument: $err");
            $bad_records++;
            next CSV_LOOP;
        }

        # The first row in the file is our column list
        if ($line_no == 1) {
            @field_list = map { lc $_ } $csv->fields;               # Convert each field name to lower case

            # Map a key column if one was not passed
            if (! $key_column) { $key_column = $field_list[0]; }

            # Continue to the next line
            next CSV_LOOP;
        }

        my %temp_hash;
        my @fields            = $csv->fields;

        # Store the data into the correct record columns
        foreach my $column (0 .. $#field_list) {
            $temp_hash{$field_list[$column]} = $fields[$column];
        }

        # Get the key from the record
        my $record_key = $temp_hash{$key_column};

        # Make sure we have a key and that it's unique
        if (defined $record_key) {
            if ($csv_hash{$record_key}) {
                $record_key = "$record_key-$line_no";
            }
        }
        else {
            next CSV_LOOP;
        }

        # Now map the record into the hash
        $csv_hash{$record_key} = \%temp_hash;
        $record = \%temp_hash;
    }
    continue {
        debug_print($DEBUG_READ_LINE, "LINE", $record)    if ($record);
        display_progress($DEBUG_PROGRESS_INDICATOR, $line_no, $total_lines);
    }

    debug_print($DEBUG_INFO, "READ", "[$line_no] line(s), [$bad_records] were rejected, from [$filename]");
    return %csv_hash;
}

##############################################################################
# Usage         :   dbm_read($filename, [$key_column])
# Purpose       :   Reads in the passed CSV and returns a hash of the data
# Returns       :   A hash of the data, the key is the first column or
#                   the optional $key_column
# Parameters    :   $filename of file to read
#                   optional $key_column
# Example       :   dbm_read("data.csv")
sub dbm_read {
    my ($filename, $key_column) = @_;

    my $dbm = tie my %dbm_outfile, 'MLDBM', "$filename.dat", O_CREAT | O_RDWR, 0666
        or quit("FATAL : Can't initialize MLDBM file: $!");

    # If the file doesn't exist or is empty, print an error message and return
    if (-z $filename) {
        debug_print($DEBUG_WARNING, "NOTICE", "File [$filename] is empty.");
        return;
    }

    debug_print($DEBUG_INFO, "FILE", "reading from file [$filename]");

    # Define some local variables
    my $total_lines = count_lines($filename);   # Get the total number of lines in the file
    my $line_no     = 0;                        # Create a variable to help us keep track of progress
    my $bad_records = 0;                        # Keep track of how many records are rejected
    my @field_list;                             # Create a variable to hold the field names
    my $record;                                 # Temporary data structure

    # We need to create an object to read the file
    my $csv = Text::CSV_XS->new({
        sep_char            =>  q{,},   # Field are comma separated
        escape_char         =>  q{`},   # Backticks are always data
        quote_char          =>  q{"},   # Quotes allowed
        binary              =>  0,      # Read in text mode
        allow_loose_quotes  =>  1,      # Allow --> data,data,some "more" data,data
    });

    # Open the file for reading
    open (my $csv_fh, "<", $filename)
        or quit("FATAL :  Unable to open [$filename] for reading.");

    # Read the file line-by-line
    CSV_LOOP:
    while (my $line = <$csv_fh>) {
        chomp($line);                   # Remove CRLF
        $line =~ s/\r//g;               # Remove CR because chomp on CYGWIN won't
        $line_no++;

        # The following two regular expressions resolve a QIP CSV issue
        $line =~ s/`/$ESCAPE_CHARACTER/g;   # Immunize against use of escape character
        $line =~ s/""""/`"`"/g;         # Special case double-double 'inside' qoutes
        $line =~ s/"""/"/g;             # Do this first to replace 'outside' quotes
        $line =~ s/""/`"/g;             # Then do this for any 'inside' quotes

        # Check for a blank line
        if (length($line) == 0) {
            next CSV_LOOP;
        }

        # Process the current line
        if (! $csv->parse($line)) {
            debug_print($DEBUG_WARNING, "REJECT", "Bad data [$line]");
            my $err = $csv->error_input;
            debug_print($DEBUG_WARNING, "ERROR", "csv->parse() failed on argument: $err");
            $bad_records++;
            next CSV_LOOP;
        }

        # The first row in the file is our column list
        if ($line_no == 1) {
            @field_list = map { lc $_ } $csv->fields;               # Convert each field name to lower case

            # Map a key column if one was not passed
            if (! $key_column) { $key_column = $field_list[0]; }

            # Continue to the next line
            next CSV_LOOP;
        }

        my %temp_hash;
        my @fields            = $csv->fields;

        # Store the data into the correct record columns
        foreach my $column (0 .. $#field_list) {
            $temp_hash{$field_list[$column]} = $fields[$column];
        }

        # Get the key from the record
        my $record_key = $temp_hash{$key_column};

        # Make sure we have a key and that it's unique
        if (defined $record_key) {
            if ($dbm->{$record_key}) {
                $record_key = "$record_key-$line_no";
            }
        }
        else {
            next CSV_LOOP;
        }

        # Now map the record into the hash
        $dbm->{$record_key} = \%temp_hash;
        $record = \%temp_hash;
    }
    continue {
        debug_print($DEBUG_READ_LINE, "LINE", $record)    if ($record);
        display_progress($DEBUG_PROGRESS_INDICATOR, $line_no, $total_lines);
    }

    debug_print($DEBUG_INFO, "READ", "[$line_no] line(s), [$bad_records] were rejected, from [$filename]");
    return $dbm;
}

##############################################################################
# Usage         :   debug_log($label, [$ref,] @message)
# Purpose       :   Prints messages to log file
# Returns       :   nothing
# Parameters    :   optional $label to print instead of "DEBUG"
#                   @message to print (will print everything followed by '\n')
# Notes         :   The label "DEBUG" is reserved with an extra space to make
#                   it six characters in length.  The idea is that this should
#                   be long enough to allow more choices while still lining up
#                   ouput.  Users should pass a six character string to keep
#                   the print layout consistent.
#
sub debug_log {
    my ($label, $first_part, @message) = @_;
    my $logfile = $LOGFILENAME;

    # Get the date and time for the log entry
    my ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset,
        $dayOfWeek, $dayOfYear, $daylightSavings) = localtime();
    my $year = $yearOffset + 1900;

    # Compensate for $month starting at 0 instead of 1
    $month ++;

    # Append leading 0 where necessary
    $month      = ($month      < 10) ? ("0" . $month     ) : $month;
    $dayOfMonth = ($dayOfMonth < 10) ? ("0" . $dayOfMonth) : $dayOfMonth;
    $hour       = ($hour       < 10) ? ("0" . $hour      ) : $hour;
    $minute     = ($minute     < 10) ? ("0" . $minute    ) : $minute;
    $second     = ($second     < 10) ? ("0" . $second    ) : $second;

    #open the debug log file in append mode
    open my $debug_log_fh, '>>', $logfile
        or quit("FATAL : Unable to open [$logfile] for writing.");

    # See if we need to change label;
    if ( !$label || $label eq $EMPTY_STRING ) {
        $label = "DEBUG [--]";
    }

    # Start the message
    print $debug_log_fh "[$year/$month/$dayOfMonth $hour:$minute:$second] $label:  ";

    # If this is a hash...
    if (is_hash($first_part)) {
        my $loop_count = 0;

        # Print each key and value
        MESSAGE_HASH_LOOP:
        foreach my $key (sort keys %{ $first_part }) {

            # Print a comma between fields
            if ($loop_count) {
                print $debug_log_fh ", ";
            }

            print $debug_log_fh "[$key=";
            if (is_array($first_part->{$key})) {
                print $debug_log_fh join(",", @{ $first_part->{$key} });
            }
            else {
                print $debug_log_fh "$first_part->{$key}";
            }
            print $debug_log_fh "]";

            $loop_count++;
        }
    }
    else {
        print $debug_log_fh "$first_part";
    }

    # Print any remaining part of the message
    print $debug_log_fh " " . join(" ", @message) . "\n";

    close $debug_log_fh;

    return;
}

##############################################################################
# Usage         :   debug_print($level, $label, [$ref,] @message)
# Purpose       :   Prints out messages of debug is enabled.  Prints more
#                   with higher levels of debug
# Returns       :   nothing
# Parameters    :   $level which must be met by $debug to print
#                   optional $label to print instead of "DEBUG"
#                   @message to print (will print everything followed by '\n')
# Notes         :   The label "DEBUG" is reserved with an extra space to make
#                   it six characters in length.  The idea is that this should
#                   be long enough to allow more choices while still lining up
#                   ouput.  Users should pass a six character string to keep
#                   the print layout consistent.
#
sub debug_print {
    my ($level, $label, $first_part, @message) = @_;

    # See if we need to change label;
    if ( !$label || $label eq $EMPTY_STRING ) {
        $label = "DEBUG";
    }

    # If debug is higher than the level, print the message and return
    if ($config->{'debug'} >= $level) {
        # Start the message
        $label = sprintf("%-6s [%02d]", $label, $level);
        print "$label:  ";

        # If this is a hash...
        if (is_hash($first_part)) {
            my $loop_count = 0;

            # Print each key and value
            MESSAGE_HASH_LOOP:
            foreach my $key (sort keys %{ $first_part }) {

                # Print a comma between fields
                if ($loop_count) {
                    print ", ";
                }

                print "[$key=";
                if (is_array($first_part->{$key})) {
                    print join(",", @{ $first_part->{$key} });
                }
                else {
                    print "$first_part->{$key}";
                }
                print "]";

                $loop_count++;
            }
        }
        else {
            print "$first_part";
        }

        # Print any remaining part of the message
        print " " . join(" ", @message) . "\n";

        # Send same output to disk
        if ($config->{'log_to_file'}) {
            debug_log($label, $first_part, @message);
        }
    }

    return;
}

##############################################################################
# Usage         :   decimal2mac($mac_address)
# Purpose       :   Takes a 12-character decimal address and converts it to
#                   a colon delimited MAC address
# Returns       :   a MAC address on success, undef on failure
# Parameters    :   $mac_address
sub decimal2mac {
    my ($mac_address) = @_;

    # Check for proper length and format
    if ( !(length $mac_address == 12) or ($mac_address =~ /[^[0-9a-f]/i)) {
        # Return undef on failure
        return;
    }

    $mac_address =~ s/(..)/$1:/g;           # Take each pair of values and add a colon after them
    $mac_address =~ s/:$//g;                # Remove the excess colon at the end of the line

    return ( $mac_address );
}

##############################################################################
# Usage         :   display_progress($debug_level, $current_record, $total_records)
# Purpose       :   Displays a progress related message
# Returns       :   nothing
# Parameters    :   $debug_level to pass to debug_print
#                   $current_record that was just processed
#                   $total_records in the group
sub display_progress {
    my ($debug_level, $current_record, $total_records) = @_;

    # Short circuit the routine if the proper debug level isn't set
    if ($debug_level > $config->{'debug'}) {
        return;
    }

    my $percent_complete = 0;

    # Make sure $total_records is at least defined
    if (! $total_records) { $total_records = 0; }

    # Use modulus to check for a remainder
    if ((($current_record % $PROGRESS_INDICATOR) == 0)
        || ($current_record == $total_records)) {
        if ($total_records) {
            $percent_complete = int(($current_record / $total_records) * 100);
            debug_print($debug_level, "------", "\tprocessed record [#$current_record] of [$total_records], [$percent_complete%] complete");
        }
        else {
            debug_print($debug_level, "------", "\tprocessed record [#$current_record]");
        }
    }

    return;
}

##############################################################################
# Usage         :   error_print($message, [$label])
# Purpose       :   Prints out an error message.  If debug level is set
#                   returns gracefully, otherwise exits.
# Returns       :   nothing
# Parameters    :   $message to print
#                   optional $label to print instead of "ERROR"
# Notes         :   The label is reserved with an extra space to make it
#                   six characters in length.  The idea is that this should
#                   be long enough to allow more choices while still lining up
#                   ouput.  Users should pass a six character string to keep
#                   the print layout consistent.
sub error_print {
    my ($message, $label) = @_;

    # See if we need to change label;
    if ( !$label || $label eq $EMPTY_STRING ) {
        $label = "ERROR";
    }

    # Print the error message
    debug_print($DEBUG_ERROR, $label, $message);

    # If debug is set, return
    if ($config->{'debug'} >= $DEBUG) {
        return;
    }

    # Exit with an error
    debug_print($DEBUG_ERROR, "QUIT", "Giving up");
    exit 1;
}

##############################################################################
# Usage         :   get_log_filename()
# Purpose       :   Generate a log filename based on the script name and date/time
# Returns       :   Return a time stamped log filename
# Parameters    :   none
sub get_log_filename {
    # Start by getting the name of the script
    my $filename = $basename;

    # Remove the .pl file extension
    $filename =~ s{.pl \z}{}gxm;

    # Get the current date and time so we can time index our filename
    my ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset,
        $dayOfWeek, $dayOfYear, $daylightSavings) = localtime();
    my $year = $yearOffset + 1900;

    # Compensate for $month starting at 0 instead of 1
    $month ++;

    # Append leading 0 where necessary
    $month      = ($month      < 10) ? ("0" . $month     ) : $month;
    $dayOfMonth = ($dayOfMonth < 10) ? ("0" . $dayOfMonth) : $dayOfMonth;
    $hour       = ($hour       < 10) ? ("0" . $hour      ) : $hour;
    $minute     = ($minute     < 10) ? ("0" . $minute    ) : $minute;
    $second     = ($second     < 10) ? ("0" . $second    ) : $second;

    # Now finish building the filename
    $filename = "$filename.$year$month$dayOfMonth.$hour$minute$second.log";

    # It shouldn't exist but let's check anyway
    if (-e $filename) {
        debug_print($DEBUG_INFO, "INFO", "Log file already exists.  Removing it.");
        unlink($filename);
    }

    return $filename;
}

##############################################################################
# Usage         :   is_array(x)
# Purpose       :   Determines if the passed reference is an array or not
# Returns       :   1 if x is an array, 0 if not
# Parameters    :   a reference
sub is_array {
    my ($ref) = @_;

    if (ref $ref eq "ARRAY") {
        return 1;
    }

    return 0;
}

##############################################################################
# Usage         :   is_hash(x)
# Purpose       :   Determines if the passed reference is a hash or not
# Returns       :   1 if x is an hash, 0 if not
# Parameters    :   a reference
sub is_hash {
    my ($ref) = @_;

    if (ref $ref eq "HASH") {
        return 1;
    }

    return 0;
}

##############################################################################
# Usage         :   is_numeric(x)
# Purpose       :   Determines if the passed reference is a natural number
# Returns       :   1 if x is a natural number, 0 if not
# Parameters    :   a value
# Note          :   A natural number is 0 (zero) or greater
sub is_numeric {
    my $value = shift;

    if ($value =~ /^\d+$/) {
        return 1;
    }

    return 0;
}

##############################################################################
# Usage         :   make_list_unique($array_ref, $separator)
# Purpose       :   Take an array and make all elements unqiue
# Returns       :   A sorted string of the unique items separated by $separator
# Returns       :   A hash or a separated list of items
# Parameters    :   A separator (such as ';' or ',')
#               :   An array containing the data to make unique
sub make_list_unique {
    my ($lists_of_items, $separator) = @_;

    if (! $separator) {
        $separator = ",";
    }

    # Create one long list of all of the values
    my $string_of_items = join($separator, @{ $lists_of_items });

    # Now split the list again so each item is a single entry
    # Some items may have actually been multiple items
    my @array_of_items = split($separator, $string_of_items);

    # Build a hash of the unique values in the array
    my %unique_items = map { $_ => 1 } @array_of_items;

    # Delete any empty hash items
    if ($unique_items{$EMPTY_STRING}) {
        delete $unique_items{$EMPTY_STRING};
    }

    if (wantarray) {
        return (sort keys %unique_items);
    }

    # List each of the items in sorted order
    my $unique_list = join($separator, sort keys %unique_items);

    return $unique_list;
}

##############################################################################
# Usage         :   quit($message)
# Purpose       :   Prints a message then exits the application
# Returns       :   nothing
# Parameters    :   $message to print
sub quit {
    # Set the carp level to find the caller to quit
    $Carp::CarpLevel = 1;

    # Print the error to the log file
    #debug_print($DEBUG_ERROR, "QUIT", "@_");

    # Croak the message
    croak "@_\n";

    # Exit with an error
    exit 1;
}

##############################################################################
# Usage         :   read_config($filename, $section, $config_record)
# Purpose       :   Read a config file (INI like) and optionally
#                   a specific section
# Returns       :   A record of the global and section options (flattened)
# Parameters    :   $filename of the config file
#                   $section name of optional section to read
#                       (all others are ignored)
#                   $config_record containing any pre-existing settings
sub read_config {
    my ($filename, $section, $record) = @_;
    my $current_section;
    my $found = 0;

    # See if the file exists
    if (-e $filename) {

        # Access the config file or signal a failure
        open my $config_fh, '<', $filename
            or quit("FATAL :  Unable to open [$filename] for reading.");

        # Decode the file contents
        CONFIG_LINE:
        while (my $line = <$config_fh>) {
            chomp($line);
            $line =~ s/\r//g;               # Remove CR because chomp on CYGWIN won't

            # Trim spaces from the front and back
            $line = trim($line);

            # Check for an empty line or a comment (# or ;)
            if (($line eq $EMPTY_STRING)
                || ($line =~ s/^$COMMENT_CHAR/$EMPTY_STRING/)) {
                next CONFIG_LINE;
            }

            # Check to see if we've reached the end of the configuration file
            # This is a special case so that anything following this directive
            #   is treated as documentation
            if ($line eq "__END__") {
                last CONFIG_LINE;
            }

            # If we find a section header, capture it
            if (($line =~ s/^\[/$EMPTY_STRING/)
                && ($line =~ s/\]$/$EMPTY_STRING/)) {

                # Did we just finish with the section we wanted?
                if (($found) || (! $section)) {
                    last CONFIG_LINE;
                }

                # Did we find the section we are looking for?
                if ($line eq $section) {
                    $found = 1;
                }

                $current_section = $line;
                next CONFIG_LINE;
            }

            # if we found a new section but it doesn't match our target...
            if ($current_section && ($current_section ne $section)) {
                next CONFIG_LINE;
            }

            # Split the name/value pair
            my @data = split("=", $line);

            # Did we get more than one part and is the second part not empty?
            if (($#data > 0) && ($data[1] ne $EMPTY_STRING)) {
                $record->{$data[0]} = $data[1];
            }
        }

        close $config_fh
            or error_print("Unable to close [$filename] after reading");
    }

    # Return the config record
    return ($record);
}

##############################################################################
# Usage         :   write_csvfile($filename, $fields_to_write, $hash_ref)
# Purpose       :   Take a hash and write specific fields to a CSV file
#               :   The first field label text is repeated on each line
#               :       (if it does not exist as a column)
#               :   The first line of the file is the list of fields with a
#               :       hash/pound ('#') sign to comment it out
# Returns       :   Nothing
# Parameters    :   The filename to write to (append mode)
#               :   The list of fields to write (from the hash)
#               :       Arrays are processed as mini-lists
#               :   A hash containing the data to write
sub write_csvfile {
    my ($filename, $flds, $hash_ref) = @_;

    # Perhaps with a larger dataset, moving to Text::CSV_XS may be better
    my $csv = Text::CSV->new();

    # Open the file or return an error
    open my $csv_fh, '>>', $filename
        or quit("FATAL :  Unable to open [$filename] for writing");

    debug_print($DEBUG_INFO, "FILE", "writing file [$filename]");

    # Split the field list into an array
    my @fields = split(" ", $flds);

    # Prepare and print the header row
    my $header_row = "#" . join(",", @fields);
    print $csv_fh "$header_row\n";

    # Variables for keeping the user informed (progress)
    my $num_keys         = scalar keys %{ $hash_ref };
    my $progress_counter = 0;

    # For each entry in the hash...
    WRITE_LOOP:
    for my $keys (sort keys %{ $hash_ref }) {
        my @data;

        # Grab a local copy of the fields
        my @field_list = @fields;

        # The first column is repeated on each line if it is not a column
        my $first_column = $field_list[0];

        if (! $hash_ref->{$keys}{$first_column}) {
            # This is not a column in the record so it should be repeated as the header
            my $column = shift @field_list;
            @data = $column;
        }

        # For each remaining field
        FIELD_LOOP:
        while ( my $fname = shift @field_list ) {

            # Does the field we want to print exist?
            if ( !$hash_ref->{$keys}{$fname} ) {
                push(@data, $EMPTY_STRING);
                next FIELD_LOOP;
            }

            # See if this column is an array
            if (is_array($hash_ref->{$keys}{$fname})) {
                my $str;

                # Join the array into a comma separated list
                $str = join(",", @{ $hash_ref->{$keys}{$fname} });

                push(@data, $str);
            }
            # See if this column is a hash
            elsif (is_hash($hash_ref->{$keys}{$fname})) {
                my $h_ref = $hash_ref->{$keys}{$fname};

                # Loop through each key of the hash
                foreach my $h_key (sort keys %{ $h_ref }) {
                    my $value;

                    # If the key points to an array and join the options together
                    if (is_array($h_ref->{$h_key})) {
                        $value = join(",", @{ $h_ref->{$h_key} });
                    }
                    else {
                        $value = $h_ref->{$h_key};
                    }

                    push(@data, $h_key);                # Push the key onto the array
                    push(@data, $value);                # Push the value onto the array
                }
            }
            else {
                push(@data, $hash_ref->{$keys}{$fname});
            }
        }

        # Combine the data array into the CSV data structure
        my $status = $csv->combine( @data );

        # Abort if there's an error
        if ( !$status ) {
            debug_print($DEBUG_ERROR, "REJECT", "write_csvfile: data=", @data);
            quit("FATAL :  Failure to create CSV data");
        }

        # Grab the CSV string in scalar format
        my $line = scalar $csv->string();

        # Print the data to file (and debug)
        print $csv_fh "$line\n";
        debug_print($DEBUG_WRITE_LINE, "LINE", $line);
    }
    continue {
        # Progress indicator
        display_progress($DEBUG_PROGRESS_INDICATOR, ++$progress_counter, $num_keys);
    }

    # Print an extra empty line in the file
    print $csv_fh "\n";

    # Close the file or return an error
    close $csv_fh
        or error_print("Unable to close [$filename] after writing");

    return;
}

##############################################################################
# Usage         :   ltrim($string)
# Purpose       :   Trims whitespace from the left of a string
# Returns       :   The string with no whitespace on the left
# Parameters    :   modified $string
sub ltrim {
    my $string = shift;
    $string =~ s{$LEADING_WHITESPACE}{$EMPTY_STRING}gxm;
    return scalar $string;
}

##############################################################################
# Usage         :   rtrim($string)
# Purpose       :   Trims whitespace from the right of a string
# Returns       :   The string with no whitespace on the right
# Parameters    :   modified $string
sub rtrim {
    my $string = shift;
    $string =~ s{$TRAILING_WHITESPACE}{$EMPTY_STRING}gxm;
    return scalar $string;
}

##############################################################################
# Usage         :   trim($string)
# Purpose       :   Trims whitespace from the left and right of a string
# Returns       :   The string with no whitespace on the left or right
# Parameters    :   modified $string
sub trim {
    my $string = shift;
    $string =~ s{$SURROUNDING_WHITESPACE}{$EMPTY_STRING}gxm;
    return scalar $string;
}



#############################################################################
#
# Application-specific sub-routines
#
#############################################################################


##############################################################################
#
# Beginning of the main part of the program
#   Main body is still further down
#
##############################################################################


##############################################################################
# Usage         :   process_config_options()
# Purpose       :   Processes command line options and reads in config file
# Returns       :   nothing, modifies global $config variable
# Parameters    :   none
sub process_config_options {
    # Create a variable to hold out options in
    my $options;

    # Get the passed parameters
    my $options_okay = GetOptions (
        #Infoblox specific options
        'server|gmip:s' => \$config->{'grid_master'},
        'username:s'    => \$config->{'username'},
        'password:s'    => \$config->{'password'},

        #Standard options
        #'i=s'       => \$options->{'source_directory'},
        #'o=s'       => \$options->{'target_directory'},
        'config=s'  => \$options->{'config_file'},
        'x=s'       => \$options->{'conf_section'},
        'debug:+'   => \$options->{'debug'},                # Allow a value to be set or incremented
        'nodebug'   => sub { $options->{'debug'} = 0; },    # Turn off debugging

        #Standard meta-options
        'help|?'    => sub { pod2usage(1); },
        'man'       => sub { pod2usage(-exitstatus => 0, -verbose => 2); },
        'usage'     => sub { pod2usage(2); },
        'version'   => sub { print "\n$ID\n$REV\n\n"; exit; },
    );

    # If we got some option we didn't expect, print a message and abort
    if ( !$options_okay ) {
        debug_print($DEBUG_ERROR, "ERROR", "An invalid option was passed on the command line.");
        debug_print($DEBUG_ERROR, "NOTICE", "Try '$basename --help' for help.");
        exit 1;
    }

    # If we didn't get passed a configuration file, let's use a default
    if ( !$options->{'config_file'}) {
        $options->{'config_file'} = $basename;
        $options->{'config_file'} =~ s{.pl \z}{.conf}gxm;
    }

    # if the file exists, read it
    if (-e $options->{'config_file'}) {
        $config = read_config($options->{'config_file'}, $options->{'conf_section'}, $config);
    }
    else {
        # look for a default config file
        $config = read_config("default.conf", $options->{'conf_section'}, $config);
    }

    # update the config data with the options passed on the command line
    foreach my $opt_key (keys %{ $options }) {
        # Make sure we didn't somehow end up with a null value
        if (defined $options->{$opt_key}) {
            $config->{$opt_key} = $options->{$opt_key};
        }
    }

    # Print out the parameters and current options
    debug_print($DEBUG, $EMPTY_STRING, "Level=$config->{'debug'}");
    debug_print($DEBUG, $EMPTY_STRING, "Progress updates every [$PROGRESS_INDICATOR] items within a group (or 100%)");

    # Print the configuration settings we're using
    foreach my $option_item ( keys %{ $config } ) {
        if ($config->{$option_item}) {
            debug_print($DEBUG, "CONFIG", "  $option_item = [$config->{$option_item}]");
        }
    }

    return;
}

##############################################################################
#
# Standard script start-up processing
#
    debug_print(1, "------", $ID);
    process_config_options();

    # Create and Infoblox connection
    my $session;

    # Create a session to an Infoblox appliance
    $session = Infoblox::Session->new(
        "master"   => $config->{'grid_master'},
        "username" => $config->{'username'},
        "password" => $config->{'password'} );

    # See if the connection attempt worked
    if ($session->status_code()) {
        my $error_text = sprintf("[%d] %s", $session->status_code(), $session->status_detail());
        error_print($error_text);
        exit 1;
    }
    debug_print($DEBUG, $EMPTY_STRING, "Session established");

    debug_print(0, "------", "==[ Begin ]==");


##############################################################################
#
# MAIN:
#   Put all new code here
#{
my $my_target_ip = "192.168.1.97";

my @retrieved_objs = $session->get(
    object       => "Infoblox::DHCP::FixedAddr",
#     network      => "192.168.1.0/24",
    ipv4addr    => "$my_target_ip",
#     network_view => "default"
);
#
#foreach my $item (@retrieved_objs) {
#    if (exists $item->{'configure_for_dhcp'}) {
#        print "$item->{'ipv4addr'} is a host object\n";
#    }
#    else {
#        print "$item->{'ipv4addr'} is a fixed address\n";
#    }
#}

#print scalar(localtime)." Retrieving AuthPolicy\n";

#$session->get(object => "Infoblox::Grid::Admin::AuthPolicy");

#print scalar(localtime)." Done\n";

print "pause";

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

Generic perl template script

=head1 SYNOPSIS

generic [-s <grid_master>] [-u <username>] [-p <password>]

See below for more description of the available options.

=head1 DESCRIPTION

This is a template script.

=head1 STANDARD OPTIONS

=over

=item   -s | --server | --gmip <grid_master>

This is the IP address or hostname of the Grid Master.
The default value is "192.168.1.2".

=item   -u | --username <username>

This is the admin username to log into the Infoblox appliance with.  The
default value is "admin".

=item   -p | --password <password>

This is the admin password to log into the Infoblox appliance with.  The
default value is "infoblox".

=item   -c | --config <filename>

This is a config file which can be used to default all standard command line
options.  For example, you may default debugging to level 2 by placing the
following line in the config file.

B<debug=2>

By default, the script will always look in the current directory for a config
file of I<script_name>.conf.  If that file does not exist, then the script will
check for B<default.conf>.

=item   -x <section_label>

This option specifies which section of configuration file should be read.  The
unlabled section at the top of the configuration file is always read.  This
option allows an additional section to be loaded.

For example, passing B<-x dns6demo> will cause the I<[dns6demo]> section of the
following config file to be loaded.

    # Top of config file
    username=admin
    password=infoblox

    [dns6demo]
    grid_master=dns6demo.infoblox.com
    username=dns6_admin

    # End of config file

The end result means the following settings will be configured:
    grid_master = dns6demo.infoblox.com
    username    = dns6_admin
    password    = infoblox

Multiple sections may exist in the configuration file.

=item   -d | --debug [<level>]

Enables debugging at the specified level or will increment the debugging level
each time the option is included on the command line.

=item        --nodebug

Disables debugging output.

=item   -v | --version

Print version information for the script.

=item   -h | --help

Print this summary

=item   --man

Displays the complete manpage then exits gracefully.

=back

=head1 COMMON USAGE

B<generic -s dns6demo.infoblox.com>

    Performs some action against the Infoblox demo system.

=head1 REQUIRED ARGUMENTS

All parameters have default values.

=head1 DIAGNOSTICS

Read the output messages or enable debugging with at least level 6.  Debugging
set to level 99 is the highest level.

=head1 AUTHOR

Don Smith (L<don@infoblox.com>) -- Author and Maintainer

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2010-2012 by Don Smith.  All rights reserved.

Anyone may modify this script for their own purposes.  A little credit
would be appreciated.

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
# 2010-04-04    :   version 1
#
# 2010-05-19    :   added support for default.conf
#
# 2011-02-11    :   added additional documentation
#               :   added Infoblox connection code
#
