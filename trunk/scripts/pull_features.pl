#!/usr/bin/perl

# A script to pull out a specific subset or list of features or lines of data 
# from a data file. Compare to Excel's VLOOKUP command, only faster.

use strict;
use Getopt::Long;
use Pod::Usage;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use tim_file_helper qw(
	open_tim_data_file
	load_tim_data_file
	write_tim_data_file
	write_summary_data
);
my $VERSION = '1.4.2';

print "\n A script to pull out specific features from a data file\n";

### Quick help
unless (@ARGV) { # when no command line options are present
	# when no command line options are present
	# print SYNOPSIS
	pod2usage( {
		'-verbose' => 0, 
		'-exitval' => 1,
	} );
}



### Get command line options
my (
	$datafile, 
	$listfile,
	$outfile,
	$sum,
	$startcolumn,
	$stopcolumn,
	$log,
	$help,
	$print_version,
);
my ($data_index, $list_index) = (-0.5, -0.5); # default 'null' values
	# I can't use 0 or a real null that could be interpreted as 0
	# because 0 may be a valid index!
GetOptions( 
	'data=s'     => \$datafile, # the input data file
	'list=s'     => \$listfile, # the list file
	'out=s'      => \$outfile, # the new output file name
	'dindex=i'   => \$data_index, # index to look up in the data file
	'lindex=i'   => \$list_index, # index of look up values in list file
	'sum'        => \$sum, # flag to re-sum the pulled values
	'starti=i'   => \$startcolumn, # index of column to start summarizing
	'stopi=i'    => \$stopcolumn, # index of column to stop summarizing
	'log!'       => \$log, # values are in log, respect log status
	'help'       => \$help, # flag to print help
	'version'    => \$print_version, # print the version
) or die " unrecognized option(s)!! please refer to the help documentation\n\n";

if ($help) {
	# print entire POD
	pod2usage( {
		'-verbose' => 2,
		'-exitval' => 1,
	} );
}

# Print version
if ($print_version) {
	print " Biotoolbox script pull_features.pl, version $VERSION\n\n";
	exit;
}



### Check for required values

unless (defined $datafile) {
	die " no input data file specified!\n";
}

unless (defined $outfile) {
	die " no output data file name given!\n";
}

unless (defined $listfile) {
	die " no list data specified!\n";
}



### Load datafile
my %data_table_elements;
print " Loading data file '$datafile'...\n";
my $main_data_ref = load_data_table_file();



### Load the list of specified values
print " Collecting lookup values from file '$listfile'...\n";
my @requests = collect_list_from_file();



### Pull out the desired features
print " Pulling features...\n";
my ($found_count, $notfound_count) = pull_requested_features();



### Write the output files
if ($found_count) {
	print "  $found_count features were found and pulled\n";
	if ($notfound_count > 0) {
		print "  $notfound_count features were not found\n";
	}
	write_files();
}
else {
	print "  Nothing found! Nothing to write!\n";
}





########################   Subroutines   ###################################

### Subroutine to collect data values from a file
sub load_data_table_file {
	
	# Open the data file and load the metadata
	my ($data_fh, $data_ref) = open_tim_data_file($datafile) or 
		die " unable to open data file '$datafile'!\n";
	
	# Determine the dataset index for the lookup values
	if ($data_index == -0.5) { # the default 'null' value
		# we must ask the user
		
		# print the headers
		print "\n There are multiple columns in the data file.\n";
		for (my $i = 0; $i < $data_ref->{'number_columns'}; $i++) {
			print "   $i\t$data_ref->{$i}{name}\n";
		}
		
		# process the answer
		print " Enter the number of the column with the gene names to match   ";
		my $answer = <STDIN>;
		chomp $answer;
		
		# check answer and return
		if (exists $data_ref->{$answer}) {
			# answer appears to be a column index
			$data_index = $answer;
		}
		else {
			die " Invalid response!\n";
		}
	}
	
	# load the data file contents into the data_table_elements hash
	# the keys are the dataset lookup values 
	# the values will be the data table row
	while (my $line = $data_fh->getline) {
		chomp $line;
		my @linedata = split /\t/, $line;
		
		# store line data
		# data_table_elements hash is global
		my $value = $linedata[$data_index] || undef;
		unless ($value) {
			warn "lookup value is not defined at line $.!\n";
			next;
		}
		if (exists $data_table_elements{$value}) {
			warn "lookup value '$value' from data table is not unique!\n" . 
				" Data loss is imminent!\n";
		}
		$data_table_elements{$value} = \@linedata;
	}
	
	# Finished loading data table into hash
	$data_fh->close;
	return $data_ref;
}



### Subroutine to collect list values from a file
sub collect_list_from_file {
	
	# load the file
	my $list_data_ref = load_tim_data_file($listfile);
	unless ($list_data_ref) {
		die " No list file loaded!\n";
	}
	#print " there are $list_data_ref->{last_row} values in list '$listfile'\n";
	
	my @list; # the array to put the final list of features into	
	
	# Check for whether the list file is a Cluster .kgg file
	if ($listfile =~ /\.kgg$/i) {
		# It is a .kgg file
		# This file is a simple two column tab-delimited file generated by 
		# Cluster. The first column contains the gene names. The second 
		# column is the group number.
		
		# we'll use the list_index as the the group number to pull out 
		if ($list_index == -0.5) {
			# we'll need to ask first
			
			# collect the groups and the numbers
			my %groups;
			for (my $row = 1; $row <= $list_data_ref->{'last_row'}; $row++) {
				$groups{ $list_data_ref->{'data_table'}->[$row][1] } += 1;
			}
			
			# ask user
			print "\n These are the group numbers in '$listfile':\n";
			foreach (sort {$a <=> $b} keys %groups) {
				print "   Group $_\thas $groups{$_} genes\n";
			}
			print " Enter the group number to use   ";
			my $answer = <STDIN>;
			chomp $answer;
			if (exists $groups{$answer}) {
				$list_index = $answer;
			}
			else {
				die " unkown response!\n";
			}
		}
		
		# now pull out the list of group genes
		for (my $row = 1; $row <= $list_data_ref->{'last_row'}; $row++) {
			if ($list_data_ref->{'data_table'}->[$row][1] == $list_index) {
				push @list, $list_data_ref->{'data_table'}->[$row][0];
			}
		}
	}
	
	else {
		# an ordinary text file
		
		# take the list from the appropriate column
		# first determine which column
		if ($list_data_ref->{'number_columns'} == 1) {
			# there is only one column in the file
			# that must be it!
			$list_index == 0;
		}
		
		elsif ($list_index == -0.5) { 
			# default 'null' value
			# since there are multiple columns, and the index wasn't defined,
			# we'll ask the user which column
			# this assumes that the first line is the column headers
			
			# print the headers
			print "\n There are multiple columns in the list.\n";
			for (my $i = 0; $i < $list_data_ref->{'number_columns'}; $i++) {
				print "   $i\t$list_data_ref->{$i}{name}\n";
			}
			
			# process the answer
			print " Enter the number of the column with the gene names to use   ";
			my $answer = <STDIN>;
			chomp $answer;
			
			# check answer and return
			if (exists $list_data_ref->{$answer}) {
				# answer appears to be a column index
				$list_index = $answer;
			}
			else {
				die " Invalid response!\n";
			}
			
		}
				
		# then walk through and collect the values from the appropriate column
		for (my $row = 1; $row < $list_data_ref->{'last_row'}; $row++) {
			# add the value in the $list_index column to the list array
			push @list, $list_data_ref->{'data_table'}->[$row][$list_index];
		}
		
	}
	
	# return the list
	return @list;
}



### Subroutine to pull the requested features
sub pull_requested_features {

	my @new_data_table; # the new data table with the pulled features
	
	# We will walk through the request list and pull the requested features
	# from the global %data_table_elements hash and put it into the new table
	
	# first copy the header row
	push @new_data_table, $main_data_ref->{'column_names'};
	
	# then the rest of the rows
	my $found = 0;
	my $notfound = 0;
	foreach my $lookup (@requests) {
		if ( exists $data_table_elements{$lookup} ) {
			# we have this value from the data table
			# copy to new table
			push @new_data_table, $data_table_elements{$lookup};
			$found++;
		}
		else {
			# we don't have this requested feature
			$notfound++;
		}
	}
	
	# Assign the new data table to the main data structure, replacing the old
	$main_data_ref->{'data_table'} = \@new_data_table;
	
	# re-calculate the last row index
	$main_data_ref->{'last_row'} = scalar @new_data_table - 1;
	
	return ($found, $notfound);
}	



### Subroutine to write the output files
sub write_files {
	# Write the file
	my $write_results = write_tim_data_file( {
		'data'      => $main_data_ref,
		'filename'  => $outfile,
	} );
	# report write results
	if ($write_results) {
		print "  Wrote new datafile '$outfile'\n";
	}
	else {
		print "  Unable to write datafile '$outfile'!!!\n";
	}
	
	# Summarize the pulled data
	if ($sum) {
		print " Generating final summed data...\n";
		my $sumfile = write_summary_data( {
			'data'         => $main_data_ref,
			'filename'     => $outfile,
			'startcolumn'  => $startcolumn,
			'endcolumn'    => $stopcolumn,
			'log'          => $log,
		} );
		if ($sumfile) {
			print "  Wrote summary file '$sumfile'\n";
		}
		else {
			print "  Unable to write summary file!\n";
		}
	}
}



__END__

=head1 NAME

pull_features.pl

=head1 SYNOPSIS

pull_features.pl --data <filename> --list <filename> --out <filename>
  
  Options:
  --data <filename>
  --list <filename>
  --out <filename>
  --dindex <integer>
  --lindex <integer>
  --sum
  --starti <integer>
  --stopi <integer>
  --log
  --help


=head1 OPTIONS

The command line flags and descriptions:

=over 4


=item --data

Specify a tim data formatted input file of genes.

=item --out

Specify the output file name. 

=item --list

Specify the name of a text file containing the feature names
or values to look up. The file must contain a column header 
that matches a column header name in the data file. Multiple 
columns may be present. A .kgg file (from a Cluster k-means 
analysis) may also be provided.

=item --dindex <integer>

Specify the index number of the column in the data file 
containing the data to look up and match. Defaults to 
interactively asking the user.

=item --lindex <integer>

Specify the index number of the column in the list file 
containing the values to look up and match if more than one 
column is present. If a k-means Cluster file (.kgg) is 
provided, then specify the gene cluster number to use. Defaults to 
interactively asking the user.

=item --sum

Indicate that the pulled data should be averaged across all 
features at each position, suitable for graphing. A separate text 
file with '_summed' appended to the filename will be written.

=item --starti <integer>

When re-summarizing the pulled data, indicate the start column 
index that begins the range of datasets to summarize. Defaults 
to the leftmost column without a standard feature description
name.

=item --stopi <integer>

When re-summarizing the pulled data, indicate the stop column
index the ends the range of datasets to summarize. Defaults
to the last or rightmost column.

=item --log

The data is in log2 space. Only necessary when re-summarizing the
pulled data.

=item --help

Display this POD documentation.

=back

=head1 DESCRIPTION

Given a list of requested feature IDs, this program will pull out those 
features (rows) from a datafile (compare to Microsoft Excel's VLOOKUP 
command). The list is provided as a separate text file. The program will 
write a new data file containing only those features it found and in the 
same order as the request list. 

The list file may be a simple text file containing the feature names of the 
features to pull. If more than one column is present in the list of lookup 
names, the index will be requested interactively from the user, or be 
specified as a command line argument. 

Alternatively, it will also accept a k-means Cluster gene file (.kgg 
extension) and all genes from the specified cluster number will be pulled. 
 
=head1 AUTHOR

 Timothy J. Parnell, PhD
 Howard Hughes Medical Institute
 Dept of Oncological Sciences
 Huntsman Cancer Institute
 University of Utah
 Salt Lake City, UT, 84112

This package is free software; you can redistribute it and/or modify
it under the terms of the GPL (either version 1, or at your option,
any later version) or the Artistic License 2.0.  








