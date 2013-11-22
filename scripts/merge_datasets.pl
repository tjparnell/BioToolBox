#!/usr/bin/perl

# A program to merge two or more dataset files


use strict;
use Getopt::Long;
use Pod::Usage;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use tim_file_helper qw(
	load_tim_data_file
	write_tim_data_file
);

print "\n A progam to merge two or more dataset files\n";


# Print help
unless (@ARGV) {
	# when no command line options are present
	# print SYNOPSIS
	pod2usage( {
		'-verbose' => 0, 
		'-exitval' => 1,
	} );
}

### Get command line options and initialize values
my (
	$lookup,
	$outfile,
	$gz,
	$help
);

# Command line options
GetOptions( 
	'lookup!'   => \$lookup, # force merging by value lookup
	'out=s'     => \$outfile, # name of output file 
	'gz!'       => \$gz, # compress output
	'help'      => \$help # request help
);

# Print help
if ($help) {
	# print entire POD
	pod2usage( {
		'-verbose' => 2,
		'-exitval' => 1,
	} );
}



# Set up output
my $output_data_ref; # the reference scalar for the output data structure


# Get the alphabet-number conversion hashes
my %letter_of = get_letters(); # convert numbers into letters
my %number_of = get_numbers(); # to convert letters into numbers


### Process and merge the files
if (scalar @ARGV < 2) {
	# nothing to merge!
	warn " At least two input files are required!\n";
	print_help();
	exit;
}
elsif (scalar @ARGV == 2) {
	# exactly two filenames are provided
	my $input_data1_ref = read_file(shift @ARGV);
	my $input_data2_ref = read_file(shift @ARGV);
	merge_two_datasets($input_data1_ref, $input_data2_ref);
}
else {
	# more than two filenames
	
	# merge the first two
	my $input_data1_ref = read_file(shift @ARGV);
	my $input_data2_ref = read_file(shift @ARGV);
	merge_two_datasets($input_data1_ref, $input_data2_ref);
	$input_data1_ref = undef;
	$input_data2_ref = undef;
	
	# merge the subsequent files
	foreach (@ARGV) {
		my $input_data_ref = read_file($_);
		add_datasets($input_data_ref);
	}
}


### Offer to re-name the datasets
print " Do you wish to rename the headers? y or n   ";
my $response = <STDIN>;
chomp $response;
if ($response eq 'y' or $response eq 'Y') { 
	# we will be re-naming headers
	
	rename_dataset_names();
}




### Print the output

# Request the output file name
# default is to simply overwrite file1
unless ($outfile) {
	print " Enter the output file name [", $output_data_ref->{'filename'}, "] ";
	$outfile = <STDIN>;
	chomp $outfile;
	if ($outfile eq '') {
		# use file 1 as the default file name
		$outfile = $output_data_ref->{'filename'};
	} 
}

# write the file
my $file_written = write_tim_data_file( {
	'data'      => $output_data_ref,
	'filename'  => $outfile,
	'gz'        => $gz,
} );
if ($file_written) {
	print " Wrote file '$file_written'\n";
}
else {
	print " No file written!\n";
}






########################   Subroutines   ###################################





### Read the input data file
sub read_file {
	# subroutine to load the time data file and print basic stats about it
	my $filename = shift;
	
	# load the file data
	my $file_data_ref = load_tim_data_file($filename);
	unless ($file_data_ref) {
		die " file '$filename' not loaded!";
	}
	
	# print the results
	print "    Loaded '$filename' with ", $file_data_ref->{'last_row'}, 
		" data rows and ", $file_data_ref->{'number_columns'}, " columns\n\n";
	
	# return
	return $file_data_ref;
}


### Merge two datasets together
sub merge_two_datasets {
	my ($input_data1_ref, $input_data2_ref) = @_;
	
	# Check the input data
	my $check = check_data_tables($input_data1_ref, $input_data2_ref);
	
	
	# Merge by lookup values
	if ($lookup or $check) {
		# we need to merge by lookup values
		merge_two_datasets_by_lookup($input_data1_ref, $input_data2_ref);
	}
	
	# Merge the two datasets blindly
	else {
		
		# determine the new order
		my @order = request_new_order($input_data1_ref, $input_data2_ref);
		
		# Initialize the output data structure if necessary
		$output_data_ref = initialize_output_data_structure($input_data1_ref); 
	
		# assign the datasets to the output data in requested order
		foreach my $request (@order) {
			
			# determine the current column index we're working with
			my $column = $output_data_ref->{'number_columns'};
			
			# add the dataset from the appropriate input file
			if ($request =~ /^\d+$/) {
				# a digit indicates a dataset from file1
				
				# copy the dataset
				for my $row (0 .. $input_data1_ref->{'last_row'}) {
					$output_data_ref->{'data_table'}->[$row][$column] = 
						$input_data1_ref->{'data_table'}->[$row][$request];
				}
				
				# copy the metadata
				copy_metadata($input_data1_ref, $request);
			} 
			elsif ($request =~ /^[a-z]$/i) {
				# a letter indicates a dataset from file2
				
				# first convert back to number
				my $number = $number_of{$request};
				
				# copy the dataset
				for my $row (0 .. $input_data2_ref->{'last_row'}) {
					$output_data_ref->{'data_table'}->[$row][$column] = 
						$input_data2_ref->{'data_table'}->[$row][$number];
				}
				
				# copy the metadata
				copy_metadata($input_data2_ref, $number);
			} 
			else {
				die " unrecognized  symbol '$request' in request! nothing done!\n";
			}
		}
	
	}
}



### merge two datasets by lookup value
sub merge_two_datasets_by_lookup {
	my ($input_data1_ref, $input_data2_ref) = @_;
	
	# determine lookup indices and order
	my ($lookup1, $lookup2, @order) = 
		request_indices_and_order($input_data1_ref, $input_data2_ref);
	
	# rearrange as necessary to make the first data structure dominant
	if ($order[0] =~ /[a-z]/i) {
		# it looks like the user wants the second file to be dominant
		# the dominant file is where we'll be taking all of the values
		
		# switch the references
		($input_data1_ref, $input_data2_ref) = 
			($input_data2_ref, $input_data1_ref);
		
		# switch the lookup indices
		($lookup1, $lookup2) = ($lookup2, $lookup1);
		
		# switch the numbers and letters
		for my $i (0 .. $#order) {
			# essenially a conditional map function
			if (/\d+/) {
				$order[$i] = $letter_of{$order[$i]};
			}
			else {
				$order[$i] = $number_of{$order[$i]};
			}
		}
	}
	
	# Index the second dataset
		# we'll be putting the lookup values into an index hash
		# where the lookup value is the key and the row number is the value
	$input_data2_ref->{'index'} = {};
	for (my $row = 1; $row <= $input_data2_ref->{'last_row'}; $row++) {
		my $key = $input_data2_ref->{'data_table'}->[$row][$lookup2];
		if (exists $input_data2_ref->{'index'}{$key}) {
			# value is not unique
			warn " lookup value '$key' in file " . 
				$input_data2_ref->{'filename'} . 
				", row $row is a duplicate!\n" . 
				" Using the first occurence value\n";
		}
		else {
			# value is ok
			$input_data2_ref->{'index'}{$key} = $row;
		}
	}
	
	# Initialize the output data structure if necessary
	$output_data_ref = initialize_output_data_structure($input_data1_ref); 
	
	# assign the datasets to the output data in requested order
	foreach my $request (@order) {
		
		# determine the current column index we're working with
		my $column = $output_data_ref->{'number_columns'};
		
		# add the dataset from the appropriate input file
		if ($request =~ /\d+/) {
			# a digit indicates a dataset from file1
			# we're assuming that file1 is dominant, we copy all the 
			# rows from file1 into output, no lookup required
			
			# copy the header
			$output_data_ref->{'data_table'}->[0][$column] = 
				$input_data1_ref->{'data_table'}->[0][$request];
			
			# copy the dataset
			for my $row (1 .. $input_data1_ref->{'last_row'}) {
				$output_data_ref->{'data_table'}->[$row][$column] = 
					$input_data1_ref->{'data_table'}->[$row][$request];
				
			}
			
			# copy the metadata
			copy_metadata($input_data1_ref, $request);
		} 
		
		elsif ($request =~ /[a-z]/i) {
			# a letter indicates a dataset from file2
			# we will have to perform the lookup here
			
			# first convert back to number
			my $number = $number_of{$request};
			
			# copy the header
			$output_data_ref->{'data_table'}->[0][$column] = 
				$input_data1_ref->{'data_table'}->[0][$number];
			
			# copy the dataset
			for my $row (1 .. $input_data1_ref->{'last_row'}) {
				# identify the appropriate row in file2 by lookup value
				my $lookup = $input_data1_ref->{'data_table'}->[$row][$lookup1];
				my $row2 = $input_data2_ref->{'index'}{$lookup} || undef;
				
				# copy the appropriate value
				if ($row2) {
					$output_data_ref->{'data_table'}->[$row][$column] = 
						$input_data2_ref->{'data_table'}->[$row2][$number];
				}
				else {
					$output_data_ref->{'data_table'}->[$row][$column] = '.';
				}
			}
			
			# copy the metadata
			copy_metadata($input_data2_ref, $number);
		} 
		else {
			die " unrecognized  symbol '$request' in request! nothing done!\n";
		}
	}
	
}



### Add datasets from one data file to the output data structure
sub add_datasets {
	my $data_ref = shift;
	
	# Check the input data
	my $check = check_data_tables($output_data_ref, $data_ref);
	
	
	# Merge by lookup values
	if ($check or $lookup) {
		# we need to merge by lookup values
		# even though we are just trying to add data from one file to the 
		# current output data structure, we're still going to force the 
		# user to go through the two dataset subroutine
		# this will force re-selecting lookup indices
		merge_two_datasets_by_lookup($output_data_ref, $data_ref);
	}
	
	# Merge the two datasets blindly
	else {
	
		# determine the new order
		my @order = request_new_order($data_ref);
		
		# assign the datasets to the output data in requested order
		foreach my $request (@order) {
			
			# determine the current column index we're working with
			my $column = $output_data_ref->{'number_columns'};
			
			# add the dataset from the appropriate input file
			if ($request =~ /^\d+$/) {
				# a digit indicates a dataset from file1
				
				# copy the dataset
				for my $row (0 .. $data_ref->{'last_row'}) {
					$output_data_ref->{'data_table'}->[$row][$column] = 
						$data_ref->{'data_table'}->[$row][$request];
				}
				
				# copy the metadata
				copy_metadata($data_ref, $request);
			} 
			else {
				die " unrecognized  symbol '$request' in request! nothing done!\n";
			}
		}
	}
}


### Request the new order
sub request_new_order {
	my @data_refs = @_;
	# Either one or two data file references may be passed
	# The dataset names will be printed listed by their index. Numbers will be
	# used for the first data file, letters for the second, if present.
	
	# Print the column headers
	if (scalar @data_refs == 1) {
		# Only one data file
		# we'll be using only numbers to list the datasets
		print_datasets($data_refs[0], 'number');
	}
	elsif (scalar @data_refs == 2) {
		# Two data files
		# use numbers for the first one
		print_datasets($data_refs[0], 'number');
		# use letters for the second one
		print_datasets($data_refs[1], 'letter');
		
	}
		
	# Request response from user
	print " Enter the columns' indices in the desired final order.\n" .
		" Separate indices with commas or specify a range (start - stop).\n   ";
	my $response = <STDIN>;
	chomp $response;
	$response =~ s/\s+//g;
	
	# Parse response
	my @order = parse_list($response); 
	
	# done
	print " using order: ", join(", ", @order), "\n";
	return @order;
}


### Request indices and then order
sub request_indices_and_order {
	my @data_refs = @_;
	# Two data references will always be passed
	# We'll ask for the lookup value indices for each
	
	# index value
	my $index1;
	my $index2;
	
	# Print the index headers
	# use numbers for the first one
	print_datasets($data_refs[0], 'number');
	# use letters for the second one
	print_datasets($data_refs[1], 'letter');
	
	# Request first index responses from user
	print " Enter the lookup value column index for first file   ";
	$index1 = <STDIN>;
	chomp $index1;
	unless ($index1 =~ /^\d+$/ and exists $data_refs[0]->{$index1}) {
		# check that it's valid
		die " unknown index value!\n";
	}
	
	# Request second index responses from user
	print " Enter the lookup value column index for second file   ";
	$index2 = <STDIN>;
	chomp $index2;
	unless ($index2 =~ /^[a-z]$/i) { 
		# check that it's valid
		die " unknown index value!\n";
	}
	$index2 = $number_of{$index2}; # convert to a number
	unless (exists $data_refs[0]->{$index2}) {
		# check that it's valid
		die " unknown index value!\n";
	}
	
	# Request order
	print " Enter the columns' indices in the desired final order.\n" .
		" Separate indices with commas or specify a range (start - stop).\n   ";
	my $response = <STDIN>;
	chomp $response;
	$response =~ s/\s+//g;
	
	# Parse response
	my @order = parse_list($response); 
	
	# done
	print " using order: ", join(", ", @order), "\n";
	return $index1, $index2, @order;
}


### Parse a string into a list
sub parse_list {
	my $string = shift;
	
	# Parse the string
	my @list;
	foreach my $item (split /,/, $string) {
		
		# comma-delimited list of items
		# may contain ranges of incremental items, check for those
		
		if ($item =~ /\-/) {
			# item is a range, specified as 'start - stop'
			
			if ($item =~ /^(\d+)\-(\d+)$/) {
				# range contains numbers, so must be from file1
				for (my $i = $1; $i <= $2; $i++) {
					# we will loop through from specified start to stop
					# add each number to the order
					push @list, $i;
				}
			} 
			
			elsif ($item =~ /^([a-z])\-([a-z])$/) {
				# range does not contain numbers, so must be from file2
				for (my $i = $number_of{$1}; $i <= $number_of{$2}; $i++) {
					# we will loop through from specified start to stop
					# converting each letter to the corresponding number for 
					# use in the for loop
					# then convert the number in $i back to a letter to add
					# to the order 
					push @list, $letter_of{$i};
				}
			} 
			
			else {
				# unrecognizable
				die " unrecognizable range order!\n";
			}
		} 
		
		else {
			# item is not a range but a single number/letter
			# add it to the order
			push @list, $item;
		}
	
	}
	
	return @list;
}



### Print the dataset indices and names for the passed data file 
sub print_datasets {
	
	# pass the data structure reference and the index type ('number' or 'letter')
	my ($data_ref, $index_type) = @_;
	
	# array to be used in the default order
	my @order;
	
	# Collect the original file name
	my $file = $data_ref->{'filename'};
	
	# print the dataset names for this datafile
	print " These are the headers in file '$file'\n";
	foreach (my $i = 0; $i < $data_ref->{'number_columns'}; $i++) {
		# walk through each dataset (column) in file
		
		# print the dataset name and it's index
		# and record the index in the order array for the default order
		if ($index_type eq 'number') {
			print '  ', $i, "\t", $data_ref->{$i}{'name'}, "\n";
			push @order, $i;
		}
		else {
			# use letters instead of numbers as the index key
			my $letter = $letter_of{$i};
			print '  ', $letter, "\t", $data_ref->{$i}{'name'}, "\n";
			push @order, $letter;
		}
	}
	
	return @order;
}




### Check the data tables for similarity
sub check_data_tables {
	my ($input_data1_ref, $input_data2_ref) = @_;
	
	# Check the feature types
	if ( 
		$input_data1_ref->{'feature'} and 
		$input_data2_ref->{'feature'} and
		$input_data1_ref->{'feature'} ne $input_data2_ref->{'feature'} 
	) {
		# Each file has feature type defined, but they're not the same
		# probably really don't want to combine these
		print " !!! The metadata feature types for both files don't match!!!\n". 
			"  Do you still want to proceed (y/n)  ";
		my $prompt = <STDIN>;
		if ($prompt =~ /^y/i) {
			print " OK. Continuing anyway\n\n\n";
		}
		else {
			exit " OK. Nothing done\n\n";
		}
	}
	
	# check line numbers
	my $status = 0;
	if ( $input_data1_ref->{'last_row'} != $input_data2_ref->{'last_row'} ) {
		# the number of rows in each data table don't equal
		# we will need to do this by lookup
		$status = 1;
	}
	return $status;
}



### Initialize the output data structure
sub initialize_output_data_structure {
	my $data_ref = shift;
	
	my %output_data;
	# we'll use the default values from file1 
	$output_data{'program'} = $data_ref->{'program'} or '';
	$output_data{'feature'} = $data_ref->{'feature'} or '';
	$output_data{'db'} = $data_ref->{'db'} or '';
	$output_data{'filename'} = $data_ref->{'filename'}; # borrow file name
	$output_data{'last_row'} = $data_ref->{'last_row'}; # should be identical

	# assign other values
	$output_data{'gff'} = 0; # this will no longer be a gff file
	$output_data{'number_columns'} = 0; # no datasets yet
	$output_data{'data_table'} = []; # empty array to be filled
	
	return \%output_data;
}



### Copy the dataset metadata
sub copy_metadata {
	
	# collect arguments
	my ($data_ref, $dataset_index) = @_;
	
	# determine current dataset index to copy into
	my $current_index = $output_data_ref->{'number_columns'};
	
	# copy the metadata
	$output_data_ref->{$current_index} = { %{ $data_ref->{$dataset_index} } };
	
	# set the original file name
	$output_data_ref->{$current_index}{'original_file'} = $data_ref->{'filename'};
	
	# reset the index
	$output_data_ref->{$current_index}{'index'} = $current_index;
	
	# increment the number of columns
	$output_data_ref->{'number_columns'} += 1;
}
	


### Re-name the dataset names
sub rename_dataset_names {
	print " For each header, type a new name or push enter to accept the current name\n";
	
	for (my $i = 0; $i < $output_data_ref->{'number_columns'}; $i++) {
		# walk through the list of columns
		
		# print the current name and it's originating file name
		print '  ', $output_data_ref->{$i}{'original_file'}, ': ', 
			$output_data_ref->{$i}{'name'}, ' ->  ';
		
		# request user input
		my $new_name = <STDIN>;
		chomp $new_name;
		
		# rename as requested
		if ($new_name) {
			# user entered a new name
			# assign new names in both metadata and column header
			$output_data_ref->{$i}{'name'} = $new_name;
			$output_data_ref->{'data_table'}->[0][$i] = $new_name;
		}
	}
}





### Generate the lookup hash for numbers to letters
sub get_letters {
	my %hash = (
		0 => 'a',
		1 => 'b',
		2 => 'c', 
		3 => 'd',
		4 => 'e',
		5 => 'f',
		6 => 'g',
		7 => 'h',
		8 => 'i',
		9 => 'j',
		10 => 'k',
		11 => 'l',
		12 => 'm',
		13 => 'n',
		14 => 'o',
		15 => 'p',
		16 => 'q',
		17 => 'r',
		18 => 's',
		19 => 't',
		20 => 'u',
		21 => 'v',
		22 => 'w',
		23 => 'x',
		24 => 'y',
		25 => 'z'
	);
	return %hash;
}


### Generate the lookup hash for letters to numbers
sub get_numbers {
	my %hash = (
		'a' => 0,
		'b' => 1,
		'c' => 2, 
		'd' => 3,
		'e' => 4,
		'f' => 5,
		'g' => 6,
		'h' => 7,
		'i' => 8,
		'j' => 9,
		'k' => 10,
		'l' => 11,
		'm' => 12,
		'n' => 13,
		'o' => 14,
		'p' => 15,
		'q' => 16,
		'r' => 17,
		's' => 18,
		't' => 19,
		'u' => 20,
		'v' => 21,
		'w' => 22,
		'x' => 23,
		'y' => 24,
		'z' => 25
	);
	return %hash;
}










__END__

=head1 NAME

merge_datasets.pl

=head1 SYNOPSIS

merge_datasets.pl [--options...] <file1> <file2> ...
  
  Options:
  --lookup
  --out <filename> 
  --(no)gz
  --help


=head1 OPTIONS

The command line flags and descriptions:

=over 4

=item --lookup

Force the program to merge data by using lookup values in each file.

=item --out <filename>

Specify the output filename. By default it uses the first file name.

=item --(no)gz

Specify whether (or not) the output file should be compressed with gzip.

=item --help

Display this POD documentation.

=back

=head1 DESCRIPTION

This program will merge two or more tab-delimited data files into one file. 
Datasets (columns) from each file are interactively chosen and then merged 
into an output file. Datasets from the third and subsequent files are 
added to the end (rightmost column) of the first two merged files.

The program blindly assumes that rows (features) are equivalent in all of the 
datasets if there are an equal number of data rows. However, if there are an 
unequal number of data rows, or the user forces by using the --lookup option, 
then dataset values are looked up first using specified lookup values before 
merging (compare with Excel VLOOKUP function). In this case, the dataset 
lookup indices from each file are requested, followed by the order of datasets 
to merge. The first index in the order determines which file is dominant, 
meaning that all rows from that file are included, and only the rows that 
match by lookup value are included from the second file. Null values are 
recorded when no match is found in the second file.

After merging, an opportunity for renaming the dataset names is 
presented.



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




