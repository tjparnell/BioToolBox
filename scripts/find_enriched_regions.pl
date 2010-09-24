#!/usr/bin/perl

# A script to look for enriched regions for a specific microarray data set

use strict;
use Getopt::Long;
use Statistics::Lite qw(mean median stddevp);
use Pod::Usage;
use Data::Dumper;
use Bio::Range;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use tim_db_helper qw(
	open_db_connection
	get_dataset_list 
	validate_dataset_list
	get_region_dataset_hash
	get_chromo_region_score
);
use tim_file_helper;

print "\n This script will find enriched regions for a specific microarray data set\n\n";

### Quick help
unless (@ARGV) { # when no command line options are present
	# when no command line options are present
	# print SYNOPSIS
	pod2usage( {
		'-verbose' => 0, 
		'-exitval' => 1,
	} );
}


### Get command line options and initialize values

# Initialize values
my (
	$dataset,
	$database,
	$outfile,
	$win,
	$step,
	$sdlimit,
	$threshold,
	$median,
	$deplete,
	$tolerance,
	$feat,
	$genes,
	$trim,
	$sort,
	$log,
	$html,
	$gff,
	$help,
	$debug,
); # command line variables

# Command line options
GetOptions( 
	'data=s'    => \$dataset, # the dataset to look for enriched regions
	'db=s'      => \$database, # database name
	'out=s'     => \$outfile, # output file name
	'win=i'     => \$win, # size of the window to scan the genome
	'step=i'    => \$step, # step size to move the window along the genome
	'sd=f'      => \$sdlimit, # the number of standard deviations above mean to set as the threshold
	'thresh=s'  => \$threshold, # the explicitly given threshold value
	'median'    => \$median, # use the median value instead of mean
	'deplete'   => \$deplete, # look for depleted regions instead of enriched
	'tol=i'     => \$tolerance, # tolerance for merging windows
	'feat!'     => \$feat, # collect feature information
	'genes'     => \$genes, # indicate a text file of overlapping genes shoudl be written
	'trim!'     => \$trim, # do trim the windows
	'sort!'     => \$sort, # sort the windows by score
	'log!'      => \$log, # dataset is in log2 space
	'gff'       => \$gff, # write out a gff file
	'html'      => \$html, # write out a html file with hyperlinks to gbrowse
	'debug'     => \$debug, # limit to chromosome 1 for debugging purposes
	'help'      => \$help, # print help
);


# Print help
if ($help) {
	# print entire POD
	pod2usage( {
		'-verbose' => 2,
		'-exitval' => 1,
	} );
}

# Check for required flags and assign undefined variables default values
unless ($database) {
	die " You must define a database!\n Use --help for more information\n";
}

$outfile =~ s/\.txt$//; # strip extension, it'll be added later

# window defaults
unless ($win) {
	$win = 250;
}
unless ($step) {
	# default is to use the window size
	$step = $win;
}
unless (defined $tolerance) {
	# default is 1/2 of the window size
	$tolerance = int($win / 2);
}

# threshold default
unless ($threshold) {
	unless ($sdlimit) {
		$sdlimit = 1.5;
		print " Using default limit of 1.5 standard deviation above the mean\n";
	}
}

# set the method of combining scores
my $method; 
if ($median) {
	# request median from the command line
	$method = 'median';
} 
else {
	#  default is average
	$method = 'mean';
}

# set log2 default
unless (defined $log) {
	# default is false
	$log = 0;
}

# set trimming default
unless (defined $trim) {
	$trim = 1;
}





#### Main #####

## Preparing global variables
	# This program predates my development of the tim data file and memory
	# data structures described in 'tim_file_helper.pm'. These structures
	# were bolted on afterwards. As such, the program still uses lots of
	# arrays described immediately below, and only at the end prior to 
	# output is a tim data structure generated.
my @windows; # a temporary of the found enriched windows
	# this is an array of arrays
	# the first array is an array of the found windows, and consists of
	# the second array which is comprised of the following elements
	# $chr, $start, $end, $window_score
my @genelist; # an array of gene names overlapping the regions
my %chrom2length; # a hash to store the chromosome lengths
my $db = open_db_connection($database);


## Begin the search for the enriched windows

# First need to get the data set name if not already provided
# Next, determine the threshold
# Finally, walk through the genome looking for enriched windows. These will be
# stored in the @windows array

# If the dataset is defined, then go with it
if ($dataset) {
	# first validate the dataset name
	my $bad_dataset = validate_dataset_list($database, $dataset);
	# this will return the name(s) of the bad datasets
	if ($bad_dataset) {
		die " The requested dataset $bad_dataset is not valid!\n";
	} 
	else {
		# returning nothing from the subroutine is good
		print " Using requested data set $dataset....\n";
	}
}	

# Otherwise ask for the data set
else {
	
	# Present the data set list to the user and get an answer
	my %datasethash = get_dataset_list($database); # list of data sets
	print "\n These are the microarray data sets in the database:\n";
	foreach (sort {$a <=> $b} keys %datasethash) {
		# print out the list of microarray data sets
		print "  $_\t$datasethash{$_}\n"; 
	}
	
	# get answer 
	print " Enter the number of the data set you would like to analyze  ";
	my $answer = <STDIN>;
	chomp $answer;
	
	# check answer
	if (exists $datasethash{$answer}) {
		$dataset = $datasethash{$answer};
		print " Using data set $dataset....\n";
	} 
	else {
		die " unknown dataset! You aren't trying more than one, are you?\n";
	}
}



## Determine the cutoff value
# the actual value used to determine if a region is enriched or not
unless (defined $threshold) { 
	# otherwise determine cutoff value from the dataset distribution
	print "  Determining threshold....\n";
	$threshold = go_determine_cutoff();
}
my $cutoff = $threshold; 
if ($log) {
	# we assume that the cutoff value is also provided as a log2 number
	# but the calculations require the value to be de-logged
	$cutoff = 2 ** $cutoff;
}

## Find the enriched regions
go_find_enriched_regions();
unless (@windows) { # exit the program if nothing found
	warn " No windows found!\n";
	exit;
}

# DEBUGGING: printing out the intermediate @windows array
if ($debug) {
	open FILE, ">$outfile.debug.post_windows.txt";
	print FILE Dumper(\@windows);
	close FILE;
}



## Merge the windows into larger regions
# this will merge the overlapping windows in @windows and put them into back
go_merge_windows(\@windows);
print "  Merged windows into " . scalar @windows . " windows\n";

# DEBUGGING: printing out the intermediate @windows array
if ($debug) {
	open FILE, ">$outfile.debug.post_merge1.txt";
	print FILE Dumper(\@windows);
	close FILE;
}



## Trim the merged windows of datapoints that are below the threshold
if ($trim) {
	print "  Trimming windows....\n";
	go_trim_windows();
	
	# DEBUGGING: printing out the intermediate @windows array
	if ($debug) {
		open FILE, ">$outfile.debug.post_trim.txt";
		print FILE Dumper(\@windows);
		close FILE;
	}
}


## Double check the merging
# Go back quickly through double-checking that we don't have two neighboring windows
# I still seem to have some slip through....
go_merge_windows(\@windows);
print "  Merged trimmed windows into " . scalar @windows . " windows\n";

# DEBUGGING: printing out the intermediate @windows array
if ($debug) {
	open FILE, ">$outfile.debug.post_merge2.txt";
	print FILE Dumper(\@windows);
	close FILE;
}


## Get score for final window
print "  Calculating final score of merged, trimmed windows....\n";
get_final_window_score();


## Sort the array by the final score of the windows
if ($sort) {
	print "  Sorting windows by score....\n";
	sort_data_by_final_score();
}

## Name the windows
name_the_windows();


## Identify features for merged windows
if ($feat) {
	print "  Identifying associated genomic features....\n";
	get_overlapping_features();
}


## Generate the final primary data hash
# this data hash is compatible with the tim data text format described in
# tim_file_helper.pm
my $main_data_ref = generate_main_data_hash();
unless ($main_data_ref) {
	die " unable to generate main data hash!\n";
}



## Print the output
# write standard output data file
unless ($outfile) {
	$outfile = "$dataset\_w$win\_s$step\_t$threshold";
}
my $write_success = write_tim_data_file( {
	'data'     => $main_data_ref,
	'filename' => $outfile,
} );
if ($write_success) {
	print " Wrote data file '$write_success'\n";
}
else {
	print " unable to write data file!\n";
}

# write html output file
if ($html) { 
	write_html_file();
}

# write gff file
if ($gff) { 
	my $method;
	if ($deplete) {
		$method = 'depleted_region';
	}
	else {
		$method = 'enriched_region';
	}
	my $gff_file = convert_and_write_to_gff_file( {
		'data'     => $main_data_ref,
		'score'    => 5,
		'name'     => 0,
		'source'   => 'find_enriched_regions.pl',
		'method'   => $method,
		'version'  => 3,
		'filename' => $outfile,
	} );
	if ($gff_file) {
		print " Wrote GFF file '$gff_file'\n";
	}
	else {
		print " unable to write GFF file!\n";
	}
}

print "All done!\n\n";




############# Subroutines ###################



### Determine the cutoff values for the dataset
sub go_determine_cutoff {
	
	# collect sample of values from the dataset
	my @chromosomes = $db->features(-type => 'chromosome'); 
	unless (@chromosomes) {
		die " unable to identify chromosome sequences in the database!\n" .
			" check the GFF3 type of your reference sequences\n";
	}
	
	# select chromosome randomly
	my $n = rand (scalar @chromosomes);
	while ($chromosomes[$n]->name =~ /chrm/) {
		# avoid that mitochrondrial chromosome like the plague!
		$n = rand (scalar @chromosomes);
	}
	
	# collect statistics on the chromosome
	print " Sampling '$dataset' values across chromosome '" . 
		$chromosomes[$n]->name . "'...\n";
	my $mean = get_chromo_region_score( {
		'db'           => $db,
		'dataset'      => $dataset,
		'method'       => 'mean',
		'chr'          => $chromosomes[$n]->name,
		'start'        => 1,
		'stop'         => $chromosomes[$n]->length,
		'log'          => $log,
	} );
	unless ($mean) { 
		die " unable to determine mean value '$dataset'!\n";
	}
	my $stdev = get_chromo_region_score( {
		'db'           => $db,
		'dataset'      => $dataset,
		'method'       => 'stddev',
		'chr'          => $chromosomes[$n]->name,
		'start'        => 1,
		'stop'         => $chromosomes[$n]->length,
		'log'          => $log,
	} );
	unless ($stdev) { 
		die " unable to determine stdev value '$dataset'!\n";
	}
	print "   the mean value is $mean and standard deviation $stdev\n";
	
	# calculate the actual cuttoff value, depending on enriched or depleted
	my $value; 
	if ($deplete) { 
		# look for depleted regions
		# cutoff is the defined multiples of std dev above the mean
		$value = $mean - ($stdev * $sdlimit); 
	} 
	else { 
		# default to look for enriched regions
		# cutoff is the defined multiples of std dev above the mean
		$value = $mean + ($stdev * $sdlimit); 
	}
	
	# conclusion
	print "  Using a threshold of $value ($sdlimit std devs)\n";
	return $value;
}



### Walk through each chromosome sequentially looking for windows of enrichment
sub go_find_enriched_regions {
	
	# print messages
	if ($deplete) {
		print "  Looking for depleted regions ";
	} 
	else {
		print "  Looking for enriched regions ";
	}
	if ($median) {
		print "using window median values\n";
	} 
	else {
		print "using window mean values\n";
	}
	
	
	## collect chromosomes and data
	# get list of chromosomes
	my @chromosomes = $db->features(-type => 'chromosome'); 
	unless (@chromosomes) {
		die " unable to identify chromosome sequences in the database!\n" .
			" check the GFF3 type of your reference sequences\n";
	}
	
	# walk through each chromosome
	foreach my $chrobj (
		# trying a Schwartzian transformation here
		map $_->[0],
		sort { $a->[1] <=> $b->[1] }
		map [$_, ($_->name =~ /(\d+)/)[0] ], 
		@chromosomes
	) {
		# sort chromosomes by increasing number
		# we're using RE to pull out the digit number in the chromosome name
		# and sorting increasingly by it
		
		# chromosome name
		my $chr = $chrobj->name; # this is actually returning an object, why????
		$chr = "$chr"; # force as string
		
		# skip mitochrondrial chromosome
		if ($chr =~ /chrm|chrmt/i) {next};
		
		
		# START DEBUGGING # 
		if ($debug) {
			# LIMIT TO ONE CHROMOSOME
			if ($chr eq 'chr2') {last} 
		}
		# END DEBUGGING #
		
		# collect the dataset values for the current chromosome
		# store in a hash the position (key) and values
		print "  Searching chromosome $chr....\n";
		
		# walk windows along the chromosome and find enriched windows
		my $length = $chrobj->stop; # length of the chromosome
		$chrom2length{$chr} = $length; # remember this length for later
		for (my $start = 1; $start < $length; $start += $step) {
			# define the window to look in
			my $end = $start + $win -1;
			# ensure don't go over chromosome length
			if ($end > $length) {
				$end = $length;
			} 
						
			# determine window value
			my $window_score = get_chromo_region_score( {
				'db'         => $db,
				'dataset'    => $dataset,
				'method'     => $method,
				'chr'        => $chr,
				'start'      => $start,
				'stop'       => $end,
				'log'        => $log,
			} );
			unless ($window_score) {
				#print "no values at $chr:$start..$end!\n"; 
				next;
			}
			if ($log) {
				$window_score = 2 ** $window_score;
			}
			
			# calculate if window passes threshold
			if ($deplete) { 
				# depleted regions
				if ($window_score <= $cutoff) { 
					# score passes our threshold
					push @windows, [$chr, $start, $end, $window_score];
				}
			} 
			else { 
				# enriched regions
				if ($window_score >= $cutoff) { 
					# score passes our threshold
					push @windows, [$chr, $start, $end, $window_score];
				}
			}
		}
		
	}
	print "  Found " . scalar @windows . " windows for $dataset.\n";
}


### Condense the list of overlapping windows
sub go_merge_windows {
 	my $array_ref = shift;
 	
 	# set up new target array and move first item over
 	my @merged; 
 	push @merged, shift @{$array_ref};
 	
 	while ( @$array_ref ) {
 		my $window = shift @{$array_ref};
 		
 		# first check whether chromosomes are equal
 		if ( $merged[-1][0] eq $window->[0] ) {
 			# same chromosome
 			
 			# generate Range objects
 			my $range1 = Bio::Range->new(
 				-start  => $merged[-1][1],
 				-end    => $merged[-1][2] + $tolerance
 				# we add tolerance only on side where merging might occur
 			);
 			my $range2 = Bio::Range->new(
 				-start  => $window->[1],
 				-end    => $window->[2]
 				# we add tolerance only on side where merging might occur
 			);
			
			# check for overlap
			if ( $range1->overlaps($range2) ) {
				# we have overlap
				# merge second range into first
				my ($mstart, $mstop, $mstrand) = $range1->union($range2);
				
				# update the merged window
				$merged[-1][1] = $mstart;
				$merged[-1][2] = $mstop;
				
				# score is no longer relevent
				$merged[-1][3] = '.';
			}
			else {
				# no overlap
				push @merged, $window;
			}
 		}
 		
 		
 		else {
 			# not on same chromosome
 			# move onto old array
 			push @merged, shift @{$array_ref};
 		}
 	}
 	
 	# Put the merged windows back
 	@{$array_ref} = @merged;
 	
}

	
	
	
### Fine trim the merged windows
sub go_trim_windows {
	# since the merged window represents a combined score from a region of 
	# multiple datapoints, the region may include data points on the edges of 
	# the region that actually do not cross the threshold
	# this subroutine will find the true endpoints of the enriched region
	# note that this method won't work well if the dataset is noisy
	
	
	# Walk through the list of merged windows
	foreach my $window (@windows) {
		
		# calculate extended window size
		my $start = $window->[1] - $tolerance;
		my $stop = $window->[2] + $tolerance;
		
		# check sizes so we don't go over limit
		if ($start < 1) {
			$start = 1;
		}
		if ($stop > $chrom2length{ $window->[0] }) {
			$stop = $chrom2length{ $window->[0] };
		}
		
		# get values across the extended window
		my %pos2score = get_region_dataset_hash( {
			'db'       => $db,
			'dataset'  => $dataset,
			'name'     => $window->[0],
			'type'     => 'chromosome',
			'start'    => $start,
			'stop'     => $stop,
		} );
		unless (%pos2score) {
			# we should be able to! this region has to have scores!
			die " unable to generate value hash for window $window->[0]:$start..$stop!\n";
		}
		
		# de-log if necessary
		if ($log) {
			foreach (keys %pos2score) {
				$pos2score{$_} = 2 ** $pos2score{$_};
			}
		}
		
		# look for first position whose value crosses the threshold
		foreach my $pos (sort {$a <=> $b} keys %pos2score) {
			if ($deplete) {
				# looking for depleted regions
				if ( $pos2score{$pos} <= $cutoff) {
					# we found one!
					# assign it to the window start
					$window->[1] = $pos;
					
					# go no further
					last;
				}
			}
			else {
				# lookig for enriched regions
				if ($pos2score{$pos} >= $cutoff) {
					# we found one!
					# assign it to the window start
					$window->[1] = $pos;
					
					# go no further
					last;
				}
			}
		}
		
		# look for last position whose value crosses the threshold
		foreach my $pos (sort {$b <=> $a} keys %pos2score) {
			# reverse sort order
			if ($deplete) {
				# looking for depleted regions
				if ($pos2score{$pos} <= $threshold) {
					# we found one!
					# assign it to the window start
					$window->[2] = $pos;
					
					# go no further
					last;
				}
			}
			else {
				# lookig for enriched regions
				if ($pos2score{$pos} >= $threshold) {
					# we found one!
					# assign it to the window start
					$window->[2] = $pos;
					
					# go no further
					last;
				}
			}
		}
		
		# what to do with single points?
		if ($window->[1] == $window->[2]) { 
			# a single datapoint
			# make it at least a small window half the size of $win
			# this is just to make the data look pretty and avoid a region
			# of 1 bp, which could interfere with the final score later on
			$window->[1] -= int($step/4);
			$window->[2] += int($step/4);
			
			# check sizes so we don't go over limit
			if ($window->[1] < 1) {
				$window->[1] = 1;
			}
			if ($window->[2] > $chrom2length{ $window->[0] }) {
				$window->[2] = $chrom2length{ $window->[0] };
			}
		}
		
	}

}
	

	
### Get the final score for the merged window and other things
sub get_final_window_score {
	for my $i (0..$#windows) {
		# arrays currently have $chr, $start, $end, $region_score
		# we will calculate a new region score, as well as the window size
		
		# determine window size
		my $size = $windows[$i][2] - $windows[$i][1] + 1;
		
		# replace the current score with the window size
		$windows[$i][3] = $size;
		# arrays now have $chr, $start, $end, $size
		
		# re-calculate window score
		my $new_score  = get_chromo_region_score( {
				'db'       => $db,
				'dataset'  => $dataset, 
				'chr'      => $windows[$i][0],
				'start'    => $windows[$i][1],
				'stop'     => $windows[$i][2],
				'method'   => $method,
				'strand'   => 'no',
				'log'      => $log,
		} );
		if ($new_score) {
			$windows[$i][4] = $new_score;
		}
		else {
			warn " unable to find regions score for region $windows[$i][0]:" . 
				 "$windows[$i][1]..$windows[$i][2] at row $i!\n";
		}
		
		# arrays now have $chr, $start, $end, $size, $finalscore
	}
}


### Collect the overlapping features of the enriched windows
sub get_overlapping_features {
	
	# walk through the list of windows
	for my $i (0..$#windows) {
		
		# collect the genomic features in the region
		my @features = $db->get_features_by_location(
			-seq_id    => $windows[$i][1],
			-start     => $windows[$i][2],
			-end       => $windows[$i][3],
		);
		
		my (@orf_list, @rna_list, @non_gene_list);
		foreach my $f (@features) {
			
			# collect info
			my $type = $f->primary_tag;
			my $name = $f->display_name;
			
			# determine which category to put the feature in
			# this is pretty generic, how useful is this, really?
			# keeping it this way to avoid breakage and rewrites....
			if ($type =~ /rna/i) {
				push @rna_list, "$type $name";
			}
			elsif ($type =~ /gene|orf/i) {
				push @orf_list, "$type $name";
			}
			else {
				push @non_gene_list, "$type $name";
			}
		}
		
		
		# tack on the list of features
		if (@orf_list) {
			push @{ $windows[$i] }, join(", ", @orf_list);
		}
		else {
			push @{ $windows[$i] }, '.';
		}
		if (@rna_list) {
			push @{ $windows[$i] }, join(", ", @rna_list);
		}
		else {
			push @{ $windows[$i] }, '.';
		}
		if (@non_gene_list) {
			push @{ $windows[$i] }, join(", ", @non_gene_list);
		}
		else {
			push @{ $windows[$i] }, '.';
		}
		# arrays now have $chr, $start, $end, $size, $finalscore,
		# plus, if requested, $orf_list, $rna_list, $non_gene_list
		
		# Record the gene names if requested
		if ($genes) { 
			foreach (@orf_list) {
				# each item is 'type name'
				# only keep the name
				push @genelist, (split / /)[1]; 
			}
			foreach (@rna_list) {
				# each item is 'type name'
				# only keep the name
				push @genelist, (split / /)[1];
			}
		}
	}
}


### Sort the array be final score
sub sort_data_by_final_score {
	
	# sort by the score value and place into a temporary array
	my @temp;
	if ($deplete) {
		# increasing order
		@temp = sort { $a->[4] <=> $b->[4] } @windows;
	}
	else {
		# decreasing order
		@temp = sort { $b->[4] <=> $a->[4] } @windows;
	}
	
	# put back
	@windows = @temp;
}


### Name the windows
sub name_the_windows {
	my $count = 1;
	foreach (@windows) {
		my $name = $dataset . '_win' . $count;
		unshift @{ $_ }, $name;
		$count++;
	}
	# arrays now have $name, $chr, $start, $end, $size, $region_score
	# plus, if requested, $orf_list, $rna_list, $non_gene_list
	
}



### Generate the main data hash compatible with tim_file_helper.pm
sub generate_main_data_hash {
	
	# generate the data hash
	my %datahash;
	
	# populate the standard data hash keys
	$datahash{'program'}        = $0;
	$datahash{'db'}             = $database;
	$datahash{'gff'}            = 0;
	$datahash{'number_columns'} = 6;
	
	# define feature depending on type of regions
	if ($deplete) {
		# depleted regions
		$datahash{'feature'} = 'depleted_regions';
	}
	else {
		# enriched regions
		$datahash{'feature'} = 'enriched_regions';
	}
	
	# set column metadata
	$datahash{0} = {
		# the window name
		'name'     => 'WindowID',
		'index'    => 0,
	};
	$datahash{1} = {
		# the chromosome
		'name'     => 'Chromosome',
		'index'    => 1,
	};
	$datahash{2} = {
		# the start position 
		# traditionally with the genome feature datasets, extra pertinant
		# information regarding the window generation goes here
		'name'     => 'Start',
		'index'    => 2,
		'win'      => $win,
		'step'     => $step,
	};
	if ($trim) {
		$datahash{2}{'trimmed'} = 1;
	} else {
		$datahash{2}{'trimmed'} = 0;
	}
	$datahash{3} = {
		# the stop position
		'name'     => 'Stop',
		'index'    => 3,
	};
	$datahash{4} = {
		# the size position
		'name'     => 'Size',
		'index'    => 4,
	};
	$datahash{5} = {
		# the score position
		# all parameters associated with the score are going to go here
		'name'     => 'Score',
		'index'    => 5,
		'dataset'  => $dataset,
		'log2'     => $log,
		'method'   => $method,
	};
	if ($threshold) {
		$datahash{5}{'threshold'} = $threshold;
	} else {
		$datahash{5}{'standard_deviation_limit'} = $sdlimit;
		$datahash{5}{'threshold'} = $cutoff;
	}
	
	# add feature metadata if it was requested
	if ($feat) {
		$datahash{6} = {
			# the orf list
			'name'  => 'ORF_Features',
			'index' => 6,
		};
		$datahash{7} = {
			# the orf list
			'name'  => 'RNA_Features',
			'index' => 7,
		};
		$datahash{8} = {
			# the orf list
			'name'  => 'Non-gene_Features',
			'index' => 8,
		};
		# update the number of columns
		$datahash{'number_columns'} = 9;
	}
	
	# check whether column headers have been added to the @windows array
	if ($windows[0][0] eq 'WindowID') {
		# it's already been done
	}
	else {
		# add new empty array for the column headers
		unshift @windows, [];
		# add the name to the empty array
		for (my $i = 0; $i < $datahash{'number_columns'}; $i++) {
			$windows[0][$i] = $datahash{$i}{'name'};
		}
	}
	
	# place the @windows array into the data hash
	$datahash{'data_table'} = \@windows;
	
	# record the index number of the last row
	#$datahash{'last_row'} = scalar(@windows) - 1;
	
	# return the reference to the generated data hash
	return \%datahash;
}




### Write the html output file
sub write_html_file {
	open HTML, ">$outfile.html";
	# print the head
	print HTML "<HTML>\n\n<HEAD>\n\t<TITLE>\n\t$outfile\n\t</TITLE>\n</HEAD>\n";
	print HTML "<BODY BGCOLOR=\"#FFFFFF\" text=\"#000000\">\n\n\n";
	print HTML "<H2>\n$outfile\n</H2>\n";
	# print the parameters
	print HTML "Program $0<p>\n"; # header information marked with #
	print HTML "Database $database<p>\n";
	print HTML "Dataset $dataset<p>\n";
	print HTML "Window $win<p>\n";
	print HTML "Step $step<p>\n";
	if ($threshold) {
		print HTML "Threshold $threshold<p>\n";
	} else {
		print HTML "Standard deviation limit $sdlimit<p>\n";
		print HTML "Threshold $cutoff<p>\n";
	}
	if ($deplete) {
		print HTML "Searching for depleted regions<p>\n";
	} else {
		print HTML "Searching for enriched regions<p>\n";
	}
	if ($median) {
		print HTML "Method median<p>\n";
	} else {
		print HTML "Method mean<p>\n";
	}
	if ($trim) {
		print HTML "Windows trimmed<p>\n";
	} else {
		print HTML "Windows not trimmed<p>\n";
	}
	if ($feat) {
		print HTML "Features collected<p>\n";
	}
	# print the table headers
	print HTML "\n\n<table border cellspacing=0 cellpadding=3>\n";
	print HTML "<tr bgcolor=\"#ccccff\">\n";
	print HTML "<th align=\"left\">WindowID</th>\n";
	print HTML "<th align=\"left\">Position</th>\n";
	print HTML "<th align=\"left\">Size</th>\n";
	print HTML "<th align=\"left\">$method score</th>\n";
	print HTML "<th align=\"left\">ORF features</th>\n";
	print HTML "<th align=\"left\">RNA features</th>\n";
	print HTML "<th align=\"left\">Non-gene features</th>\n";
	print HTML "</tr>\n\n";
	
	# print the data
	my $gbrowse = "http://m000237.hci.utah.edu/cgi-bin/gbrowse/$database/?"; # hyperlink to machine & gbrowse
	for my $i (0..$#windows) {
		# http://m000237.hci.utah.edu/cgi-bin/gbrowse/cerevisiae/?name=chr1:137066..145763;enable=RSC_ChIP_ypd_244k;h_region=chr1:142066..143368@lightcyan
		my $position = "$windows[$i][1]:$windows[$i][2]..$windows[$i][3]"; # chromosome:start-stop
		
		# set size of selected region for gbrowse
		# data should now have $window_name, $chr, $start, $end, $size, $region_score
		my ($start, $stop);
		if ($windows[$i][4] < 500) { 
			# size is under 500 bp, set 2 kb region
			$start = $windows[$i][2] - 1000;
			$stop = $windows[$i][2] + 999;
		} 
		elsif ($windows[$i][4]  < 1000) { 
			# size is under 1 kb, set 5 kb region
			$start = $windows[$i][2] - 2500;
			$stop = $windows[$i][2] + 2499;
		} 
		elsif ($windows[$i][4]  < 5000) { 
			# size is under 5 kb, set 10 kb region
			$start = $windows[$i][2] - 5000;
			$stop = $windows[$i][2] + 4999;
		} 
		else { 
			# size is really big, set 20 kb region
			$start = $windows[$i][2] - 10000;
			$stop = $windows[$i][2] + 9999;
		}
		if ($start < 0) {$start = 1} # in case we're at left end of chromosome
		
		# generate hypertext reference
		my $region = "name=$windows[$i][1]:$start\..$stop";
		my $track = "enable=$dataset";
		my $highlight = "h_region=$position\@bisque";
		my $link = $gbrowse . "$region;$track;$highlight";
		
		# generate table data
		print HTML "<tr>\n";
		print HTML "<td><a href=\"$link\">$windows[$i][0]</a></td>\n"; 
			# windowID with hyperlink text
		print HTML "<td>$position</td>\n"; # position
		print HTML "<td>$windows[$i][4]</td>\n"; # size
		print HTML "<td>$windows[$i][5]</td>\n"; # score
		print HTML "<td>$windows[$i][6]</td>\n"; # ORF features
		print HTML "<td>$windows[$i][7]</td>\n"; # RNA features
		print HTML "<td>$windows[$i][8]</td>\n"; # non-gene features
		print HTML "</tr>\n\n";
	}
	# close up
	print HTML "</table>\n";
	print HTML "</BODY>\n</HTML>\n";
	close HTML;
	print " Wrote html file $outfile.html\n";
}





__END__

=head1 NAME

find_enriched_regions.pl

=head1 SYNOPSIS
 
 find_enriched_regions.pl --db <db_name> [--options]
 
  Options:
  --db <db_name>
  --data <dataset>
  --out <filename>
  --win <integer>
  --step <integer>
  --tol <integer>
  --thresh <number>
  --sd <number>
  --median
  --deplete
  --(no)trim
  --(no)sort
  --(no)feat
  --(no)log
  --genes
  --gff
  --gz
  --help

 
=head1 OPTIONS

The command line flags and descriptions:

=over 4

=item --db <database_name>

Specify a Bioperl Bio::DB::SeqFeature::Store database. Required.

=item --data <dataset>

Specify the name of the dataset from which to collect the scores. 
If not specified, then the data set may be chosen interactively 
from a presented list.

=item --out <filename>

Specify the output file name. If not specified, then it will be 
automatically generated from dataset, window, step, and threshold 
values.

=item --win <integer>

Specify the genomic bin window size in bp. Default value is 250 bp.

=item --step <integer>

Specify the step size for moving the window. Default value is 
equal to the window size.

=item --tol <integer>

Specify the tolerance distance when merging windows together. 
Windows not actually overlapping but within this tolerance 
distance will actually be merged. Default value is 1/2 the 
window size.

=item --thresh <number>

Specify the window score threshold explicitly rather than calculating
a threshold based on standard deviations from the mean.

=item --sd <number>

Specify the multiple of standard deviations above the mean as a
window score threshold. Default is 1.5 standard deviations. Be 
quite careful with this method as it attempts to pull all of the 
datapoints out of the database to calculate the mean and 
standard deviation - which may be acceptable for limited tiling 
microarrays but not acceptable for next generation sequencing 
data with single bp resolution.

=item --median

Indicate that a median score value should be calculated within each
window rather than the default mean when determining whether the 
window exceeds the threshold.

=item --deplete

Specify whether depleted regions should be reported instead. 
For example, windows whose scores are 1.5 standard deviations 
below the mean, rather than above.

=item --(no)trim

Indicate that the merged windows should (not) be trimmed of below 
threshold scores on the ends of the window. Normally when windows 
are merged, there may be some data points on the ends of the 
windows whose scores don't actually pass the threshold, but were 
included because the entire window mean (or median) exceeded 
the threshold. This step removes those data points. The default 
behavior is true.

=item --(no)feat

Indicate that features overlapping the windows should be 
identified. The default behavior is false.

=item --genes

Write out a text file containing a list of the found overlapping genes.

=item --gff

Indicate that a GFF version 3 file should be written out in
addition to the data text file.

=item --(no)log

Flag to indicate that source data is (not) log2, and to calculate 
accordingly and report as log2 data.

=item --gz

Compress the output file through gzip.

=item --help

Display the POD documentation.

=back

=head1 DESCRIPTION

This program will search for regions in the genome that are enriched for a 
particular data set. It walks through each chromosome using a 
window of specified size (default 500 bp) and specified step size (default 100
bp). Data scores within a window that exceed a determined threshold
will be noted. Adjacent windows are merged and then trimmed on the ends to the
minimum thresholded window.

The threshold scores for identifying an enriched region may either be 
explicitly set or automatically determined from the mean and standard 
deviation (SD) of the entire collection of datapoints across the genome. 
This, of course, assumes a normal distribution of datapoint scores, which may 
or may not be suitable for the particular dataset. Note that the 
automatic method may not appropriate for very extremely large datasets 
(e.g. next generation sequencing) as it attempts to calculate the mean and SD 
on all of the datapoints in the database. 

The program writes out a tim data formatted text file consisting of chromosome, 
start, stop, score, and overlapping gene or non-gene genomic features. It 
will optionally write a GFF file.


=head1 AUTHOR

 Timothy J. Parnell, PhD
 Howard Hughes Medical Institute
 Dept of Oncological Sciences
 Huntsman Cancer Institute
 University of Utah
 Salt Lake City, UT, 84112





