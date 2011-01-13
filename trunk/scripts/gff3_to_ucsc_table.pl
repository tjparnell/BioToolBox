#!/usr/bin/perl

# This script will convert a GFF3 file to a UCSC style gene table

# This should complement the biotoolbox scripts ucsc_table2gff3.pl and
# get_ensembl_annotation.pl
# 


use strict;
use Getopt::Long;
use Pod::Usage;
use IO::File;
use Bio::Tools::GFF;
use Bio::SeqFeature::Generic;

#use Data::Dumper;


print "\n This program will convert a GFF3 file to UCSC gene table\n";

### Quick help
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
	$infile,
	$outfile,
	$help
);

# Command line options
GetOptions( 
	'in=s'      => \$infile, # the gff3 data file
	'out=s'     => \$outfile, # name of output file 
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



### Check for requirements
unless ($infile) {
	$infile = shift @ARGV or
		die " no input file! use --help for more information\n";
}
unless ($infile =~ /\.gff3?$/i) {
	die " input file doesn't have a gff extension! Is this a GFF3 file?\n";
}

if ($outfile) {
	# be nice and add an extension for them if it's missing
	unless ($outfile =~ /\.txt$/) {
		$outfile .= '.txt';
	}
}
else {
	# define a new output file name for them
	$outfile = $infile;
	$outfile =~ s/\.gff3?$/_ucsc_genetable.txt/;
}




### Open the input and ouput files
# Open the input GFF file
my $in_fh = new IO::File $infile, 'r';
unless ($in_fh) {
	die " unable to open input file '$infile'!\n";
}

# Open the output gene table file
my $outfh = new IO::File $outfile, 'w';
unless ($outfh) {
	die " unable to open file handle for '$outfile'!\n";
}

# Print headers
$outfh->print("#bin	name	chrom	strand	txStart	txEnd	cdsStart	cdsEnd	exonCount	exonStarts	exonEnds	score	name2	cdsStartStat	cdsEndStat	exonFrames\n");



### Process the GFF3 table
# initialize global variables
my $count = 0; # a count of written features
my %unknowns; # a hash of unrecognized feature types to report at the end
process_gff_file_to_table();






### Finished

# Close output file
$outfh->close;

# print warnings about unknown feature types
if (%unknowns) {
	foreach (sort {$a cmp $b} keys %unknowns) {
		print " Found $unknowns{$_} unrecognized features of '$_'!\n";
	}
}

print " Finished! Wrote $count features to file '$outfile'\n";






########################   Subroutines   ###################################


sub process_gff_file_to_table {
	
	# Collect the top features for each sequence group.
	# Rather than going feature by feature through the gff,
	# we'll load the top features, which will collect all the features 
	# and assemble appropriate feature -> subfeatures according to the 
	# parent - child attributes.
	# This may (will?) be memory intensive. This can be limited by 
	# including '###' directives in the GFF3 file after each chromosome.
	# This directive tells the parser that all previously opened feature 
	# objects are finished and may be closed.
	# Without the directives, all feature objects loaded from the GFF3 file 
	# will be kept open until the end of the file is reached. 
	
	my $gff = Bio::Tools::GFF->new(-gff_version => 3) or 
		die " unable to create GFF object!\n";
	
	while (my @top_features = collect_top_features($gff) ) {
		
		# processing statement
		print " Collected ", scalar(@top_features), " features from ",
			" region '", $top_features[0]->seq_id, "'\n";
		
		# Process the top features
		while (@top_features) {
			my $feature = shift @top_features;
			my $type = $feature->primary_tag;
			
			# check for chromosome
			if ($type =~ /chromosome|contig|scaffold|sequence|region/i) {
				next;
			}
			
			# process the features
			if ($type eq 'gene') {
				# a gene object, we will need to process it's transcript subfeatures
				
				# process the gene object
				process_gene($feature);
				
			}
			
			elsif ($type eq 'mRNA') {
				# a coding transcript
				
				# first need to initialize the ucsc table object
				my $ucsc_transcript = initialize_transcript($feature);
				
				# process the gene object
				process_transcript($ucsc_transcript, $feature);
			}
			
			elsif ($type =~ /rna|noncoding/i) {
				# a non-coding RNA transcript
				
				# first need to initialize the ucsc table object
				my $ucsc_transcript = initialize_transcript($feature);
				
				# process the gene object
				process_nc_transcript($ucsc_transcript, $feature);
			}
			
			elsif ($type =~ /transcript/) {
				# we'll assume this is a protein_coding transcript?
				# hopefully noncoding transcripts will be caught earlier
				
				# first need to initialize the ucsc table object
				my $ucsc_transcript = initialize_transcript($feature);
				
				# process the gene object
				process_transcript($ucsc_transcript, $feature);
			}
			
			else {
				# catchall for unrecognized feature types
				# record and warn at end
				$unknowns{$type} += 1;
				next;
			}
			
		}
		
		# print running total
		print "  wrote $count features so far\n";
	}
}




### Initialize a data structure for the UCSC table line item
sub initialize_transcript {
	# a hash structure storing the fields to be used in an UCSC gene table
	# these are UCSC gene table headers
	# bin	name	chrom	strand	txStart	txEnd	cdsStart	cdsEnd	exonCount	exonStarts	exonEnds	score	name2	cdsStartStat	cdsEndStat	exonFrames
	
	my $feature = shift;
	
	# collect the name for the transcript
	my $name;
	if ($feature->has_tag('Name')) {
		# Use the Name tag
		($name) = $feature->get_tag_values('Name');
	}
	else {
		# Or at the very least the ID, it does have an ID, right?
		($name) = $feature->get_tag_values('ID');
	}
	
	# Fill the data hash
	my %transcript = (
		'name'         => $name,
		'name2'        => undef,
		'chr'          => $feature->seq_id,
		'strand'       => $feature->strand == 1 ? '+' : '-',
		'txStart'      => undef,
		'txEnd'        => undef,
		'cdsStart'     => undef,
		'cdsEnd'       => undef,
		'exonCount'    => 0,
		'exonStarts'   => [],
		'exonEnds'     => [],
		'score'        => 0,
		'cdsStartStat' => undef,  
		'cdsEndStat'   => undef, 
		'exonFrames'   => [],
	);
	
	# get score, rarely used, but just in case
	my $score = $feature->score;
	if ($score and $score ne '.') {
		$transcript{score} = $score;
	}
	
	return \%transcript;
}



### process a gene
sub process_gene {
	my $gene = shift;
	
	# we need to process the child subfeature transcripts
	# these should be the first level subfeatures
	# walk through each one
	foreach my $subfeat ($gene->get_SeqFeatures) {
		
		# check the type, and process accordingly
		my $type = $subfeat->primary_tag;
		
		if ($type eq 'mRNA') {
			# a protein coding transcript
			
			# initialize the gene table line structure
			my $ucsc = initialize_transcript($subfeat);
			
			# identify a second name from the gene
			collect_second_name($ucsc, $gene);
			
			# process the transcript
			process_transcript($ucsc, $subfeat);
		}
		
		elsif ($type =~ /rna/i) {
			# other types of non-coding RNA species
			# should cover misc_RNA snRNA snoRNA ncRNA rRNA tRNA miRNA etc.
			
			# initialize the gene table line structure
			my $ucsc = initialize_transcript($subfeat);
			
			# identify a second name from the gene
			collect_second_name($ucsc, $gene);
			
			# process the transcript
			process_nc_transcript($ucsc, $subfeat);
		}
		
		elsif ($type eq 'exon') {
			# an exon, skip for now
			next;
		}
		
		elsif ($type =~ /codon/) {
			# start_codon or stop_codon, skip for now
			next;
		}
		
		else {
			# catchall for unrecognized feature types
			# record and warn at end
			$unknowns{$type} += 1;
			next;
		}
		
	}
}



### Find second or alternate name
sub collect_second_name {
	my ($ucsc, $feature) = @_;
	
	# check for alternate gene name, 
	if ($feature->has_tag('Alias')) {
		# Preferentially use the alias tag
		my @aliases = $feature->get_tag_values('Alias');
		$ucsc->{'name2'} = join(',', @aliases);
	}
	elsif ($feature->has_tag('Name')) {
		# Or use the Name tag
		my @names = $feature->get_tag_values('Name');
		$ucsc->{'name2'} = $names[0];
	}
	else {
		# Or at the very least the ID, it does have an ID, right?
		my @IDs = $feature->get_tag_values('ID');
		$ucsc->{'name2'} = $IDs[0];
	}
}





### process a transcript
sub process_transcript {
	my ($ucsc, $transcript) = @_;
	
	# Record coordinates for this transcript
	$ucsc->{'txStart'} = $transcript->start;
	$ucsc->{'txEnd'}   = $transcript->end;
	
	# identify a second name from the transcript if necessary
	unless (defined $ucsc->{'name2'}) {
		collect_second_name($ucsc, $transcript);
	}
		
	# Get the subfeatures of the transcript
	# these should be utrs, cds, exons, introns
	my @subfeatures = $transcript->get_SeqFeatures;
	foreach my $subf (@subfeatures) {
		
		# check the type
		my $type = $subf->primary_tag;
		
		# process accordingly
		if ($type eq 'CDS') {
			process_cds_exon($ucsc, $subf);
		}
		elsif ($type =~ /utr|untranslated/i) {
			process_utr($ucsc, $subf);
		}
		elsif ($type eq 'exon') {
			# should I work with these? Best to work with CDS
		}
		elsif ($type eq 'start_codon') {
			# should I work with these? Best to work with CDS
		}
		elsif ($type eq 'stop_codon') {
			# should I work with these? Best to work with CDS
		}
		elsif ($type eq 'intron') {
			# ignore introns
		}
		else {
			# catchall for unrecognized feature types
			# record and warn at end
			$unknowns{$type} += 1;
			next;
		}
	}
	
	# the transcript should be finished now
	# print the transcript
	print_table_item($ucsc);
}



### process a noncoding transcript
sub process_nc_transcript {
	my ($ucsc, $transcript) = @_;
	
	# Record coordinates for this transcript
	$ucsc->{'txStart'}  = $transcript->start;
	$ucsc->{'txEnd'}    = $transcript->end;
	$ucsc->{'cdsStart'} = $transcript->end; # no cds, so set to end
	$ucsc->{'cdsEnd'}   = $transcript->end;
	
	# Get the subfeatures of the transcript
	# these should be non-coding exons
	my @subfeatures = $transcript->get_SeqFeatures;
	
	# process subfeatures, if there are any
	if (@subfeatures) {
		foreach my $subf (@subfeatures) {
			
			# look for exons, could be exon or noncoding_exon
			if ($subf->primary_tag =~ /exon/i) {
				# record the coordinates and information for this exon
				push @{ $ucsc->{'exonStarts'} }, $subf->start;
				push @{ $ucsc->{'exonEnds'} }, $subf->end;
				push @{ $ucsc->{'exonFrames'} }, '-1';
				$ucsc->{'exonCount'} += 1;
			}
			else {
				# catchall for unrecognized feature types
				# record and warn at end
				$unknowns{$subf->primary_tag} += 1;
				next;
			}
		}
	}
	else {
		# no subfeatures? I guess it's just one exon
		push @{ $ucsc->{'exonStarts'} }, $transcript->start;
		push @{ $ucsc->{'exonEnds'} }, $transcript->end;
		push @{ $ucsc->{'exonFrames'} }, '-1';
		$ucsc->{'exonCount'} += 1;
	}
	
	# the transcript should be finished now
	# print the transcript
	print_table_item($ucsc);
}



### process UTR
sub process_utr {
	my ($ucsc, $utr) = @_;
	
	# record the coordinates and information for this exon
	push @{ $ucsc->{'exonStarts'} }, $utr->start;
	push @{ $ucsc->{'exonEnds'} }, $utr->end;
	push @{ $ucsc->{'exonFrames'} }, '-1';
	$ucsc->{'exonCount'} += 1;
}



### process coding Exon
sub process_cds_exon {
	my ($ucsc, $utr) = @_;
	
	# record the coordinates and information for this exon
	push @{ $ucsc->{'exonStarts'} }, $utr->start;
	push @{ $ucsc->{'exonEnds'} }, $utr->end;
	push @{ $ucsc->{'exonFrames'} }, $utr->frame;
	$ucsc->{'exonCount'} += 1;
}



### print the completed UCSC table line item
sub print_table_item {
	my $ucsc = shift;
	
	### Merge UTRs and CDS elements into exons
		# The UCSC table works with exons, and explicitly defines coding starts 
		# and stops, whereas the GFF3 gene structure typically has explicitly 
		# defined UTRs and CDS, rather than simply exons. Thus, we'll need to 
		# merge those adjoining UTRs and CDSs into a single exon.
	my @starts; # to store final fixed coordinates
	my @ends;
	my @frames;
	
	# collect the list of subfeature starts and array positions
	my %exonStarts;
	for (my $i = 0; $i < $ucsc->{'exonCount'}; $i++) {
		$exonStarts{$i} = $ucsc->{'exonStarts'}->[$i];
	}
	# sort by start position, since it's possible they weren't returned by 
	# the gff parser in genomic order
	foreach my $i (sort {$exonStarts{$a} <=> $exonStarts{$b}} keys %exonStarts) {
		push @starts, $ucsc->{'exonStarts'}->[$i];
		push @ends, $ucsc->{'exonEnds'}->[$i];
		push @frames, $ucsc->{'exonFrames'}->[$i];
	}
	# empty the UCSC coordinates, we'll be replacing them
	$ucsc->{'exonStarts'} = [];
	$ucsc->{'exonEnds'}   = [];
	$ucsc->{'exonFrames'} = [];
	
	# adjust starts for interbase
	@starts = map {$_ -= 1} @starts;
	$ucsc->{'txStart'} -= 1;
	
	# put the first exon in
	push @{ $ucsc->{'exonStarts'} }, shift @starts;
	push @{ $ucsc->{'exonEnds'} }, shift @ends;
	push @{ $ucsc->{'exonFrames'} }, shift @frames;
	
	# Look for exons to merge, work by strand
	if ($ucsc->{'strand'} eq '+') {
		# forward strand
		
		# check start completeness
		if ( $ucsc->{'exonFrames'}->[0] == -1) {
			# the first exon looks to be a UTR it is probably complete
			$ucsc->{'cdsStartStat'} = 'cmpl';
		}
		else {
			# no utr
			$ucsc->{'cdsStartStat'} = 'incmpl';
			
			# also set the cdsStart
			$ucsc->{'cdsStart'} = $ucsc->{'exonStarts'}->[0];
		}
		
		# check for potential exons to merge
		while (@starts) {
			
			# get the next exon
			my $start = shift @starts;
			my $end   = shift @ends;
			my $frame = shift @frames;
			
			# check for a utr-cds junction
			if (
				$ucsc->{'exonFrames'}->[-1] == -1 and
				$frame != -1 and
				$start - $ucsc->{'exonEnds'}->[-1] == 0
			) {
				# merge the exons
				$ucsc->{'exonEnds'}->[-1] = $end;
				$ucsc->{'exonFrames'}->[-1] = $frame;
				
				# set the cdsStart
				$ucsc->{'cdsStart'} = $start;
			}
			
			# check for cds-utr junction
			elsif (
				$ucsc->{'exonFrames'}->[-1] != -1 and
				$frame == -1 and
				$start - $ucsc->{'exonEnds'}->[-1] == 0
			) {
				# first set the cdsEnd
				$ucsc->{'cdsEnd'} = $ucsc->{'exonEnds'}->[-1];
				
				# next merge the exons
				$ucsc->{'exonEnds'}->[-1] = $end;
				
				# set the cdsEndStat
				$ucsc->{'cdsEndStat'} = 'cmpl';
			}
			
			# else a regular exon
			else {
				push @{ $ucsc->{'exonStarts'} }, $start;
				push @{ $ucsc->{'exonEnds'} }, $end;
				push @{ $ucsc->{'exonFrames'} }, $frame;
				
				# check if we need to define cdsStart
				# for those rare genes that the utr cds boundary falls on an intron
				if (
					$ucsc->{'exonFrames'}->[-2] == -1 and
						# the [-1] frame was just added, so need to look at [-2]
					$frame != -1 and 
					!defined $ucsc->{'cdsStart'}
				) {
					$ucsc->{'cdsStart'} = $start;
				}
				
				# check if we need to define cdsEnd
				# for those rare genes that the cds utr boundary falls on an intron
				if (
					$ucsc->{'exonFrames'}->[-2] != -1 and
						# the [-1] frame was just added, so need to look at [-2]
					$frame == -1 and
					!defined $ucsc->{'cdsEnd'}
				) {
					# set cdsEnd and cdsEndStat
					$ucsc->{'cdsEnd'} = $ucsc->{'exonEnds'}->[-2];
					$ucsc->{'cdsEndStat'} = 'cmpl';
				}
			}
			
		}
		
		# check end completeness
		if ( $ucsc->{'exonFrames'}->[-1] == -1) {
			# the last exon looks to be a UTR it is probably complete
			$ucsc->{'cdsEndStat'} = 'cmpl' unless 
				defined $ucsc->{'cdsEndStat'};
		}
		else {
			# no utr
			$ucsc->{'cdsEndStat'} = 'incmpl';
			unless (defined $ucsc->{'cdsEnd'}) {
				$ucsc->{'cdsEnd'} = $ucsc->{'exonEnds'}->[-1];
			}
		}
		
	}
	
	
	else {
		# reverse strand
		
		# check end completeness
		if ( $ucsc->{'exonFrames'}->[0] == -1) {
			# the last exon looks to be a UTR it is probably complete
			$ucsc->{'cdsStartStat'} = 'cmpl';
		}
		else {
			# no utr
			$ucsc->{'cdsStartStat'} = 'incmpl';
			
			# also set the cdsStart 
				# contrary to what you might think, cdsStart doesn't indicate
				# the ATG position, just the genomic start coordinate
			$ucsc->{'cdsStart'} = $ucsc->{'exonStarts'}->[0];
		}
		
		# check for potential exons to merge
		while (@starts) {
			
			# get the next exon
			my $start = shift @starts;
			my $end   = shift @ends;
			my $frame = shift @frames;
			
			# check for a utr-cds junction
			if (
				$ucsc->{'exonFrames'}->[-1] == -1 and
				$frame != -1 and
				$start - $ucsc->{'exonEnds'}->[-1] == 0
			) {
				# merge the exons
				$ucsc->{'exonEnds'}->[-1] = $end;
				$ucsc->{'exonFrames'}->[-1] = $frame;
				
				# set the cdsStart
				$ucsc->{'cdsStart'} = $start; 
			}
			
			# check for cds-utr junction
			elsif (
				$ucsc->{'exonFrames'}->[-1] != -1 and
				$frame == -1 and
				$start - $ucsc->{'exonEnds'}->[-1] == 0
			) {
				# first set the cdsEnd
				$ucsc->{'cdsEnd'} = $ucsc->{'exonEnds'}->[-1];
				$ucsc->{'cdsEndStat'} = 'cmpl';
				
				# now merge the exons
				$ucsc->{'exonEnds'}->[-1] = $end;
				
			}
			
			# else a regular exon
			else {
				push @{ $ucsc->{'exonStarts'} }, $start;
				push @{ $ucsc->{'exonEnds'} }, $end;
				push @{ $ucsc->{'exonFrames'} }, $frame;
				
				# check if we need to define cdsStart
				# for those rare genes that the utr cds boundary falls on an intron
				if (
					$ucsc->{'exonFrames'}->[-2] == -1 and
						# the [-1] frame was just added, so need to look at [-2]
					$frame != -1 and 
					!defined $ucsc->{'cdsStart'}
				) {
					$ucsc->{'cdsStart'} = $start;
				}
				
				# check if we need to define cdsEnd
				# for those rare genes that the cds utr boundary falls on an intron
				if (
					$ucsc->{'exonFrames'}->[-2] != -1 and
						# the [-1] frame was just added, so need to look at [-2]
					$frame == -1 and
					!defined $ucsc->{'cdsEnd'}
				) {
					$ucsc->{'cdsEnd'} = $ucsc->{'exonEnds'}->[-2];
					$ucsc->{'cdsEndStat'} = 'cmpl';
				}
			}
			
		}
		
		# check start completeness
		if ( $ucsc->{'exonFrames'}->[-1] == -1) {
			# the first exon looks to be a UTR it is probably complete
			$ucsc->{'cdsEndStat'} = 'cmpl' unless 
				defined $ucsc->{'cdsEndStat'};
		}
		else {
			# no utr
			$ucsc->{'cdsEndStat'} = 'incmpl';
			unless (defined $ucsc->{'cdsEnd'}) {
				$ucsc->{'cdsEnd'} = $ucsc->{'exonEnds'}->[-1];
			}
		}
		
	}
	### Finished merging exons
	
	
	# Update exonCount
	$ucsc->{'exonCount'} = scalar @{ $ucsc->{'exonStarts'} };
	
	# check for non-coding genes
	my $non_coding_check = 0;
	foreach (@{ $ucsc->{'exonFrames'} }) {
		if ($_ != -1) {
			# a coding exon
			$non_coding_check++;
			last;
		}
	}
	unless ($non_coding_check) {
		# there are no coding exons
		$ucsc->{'cdsStartStat'} = 'none';
		$ucsc->{'cdsEndStat'} = 'none';
		# the cdsStart and cdsEnd should already be set, but just in case
		$ucsc->{'cdsStart'} = $ucsc->{'txEnd'};
		$ucsc->{'cdsEnd'} = $ucsc->{'txEnd'};
	}
	
	
	
	
	### We finally print
	#print Dumper($ucsc);
	my $string = join("\t", (
	# bin	name	chrom	strand	txStart	txEnd	cdsStart	cdsEnd	exonCount	exonStarts	exonEnds	score	name2	cdsStartStat	cdsEndStat	exonFrames
		0, # bin is for UCSC internal db use, just use a dummy number here
		$ucsc->{'name'},
		$ucsc->{'chr'},
		$ucsc->{'strand'},
		$ucsc->{'txStart'},
		$ucsc->{'txEnd'},
		$ucsc->{'cdsStart'},
		$ucsc->{'cdsEnd'},
		$ucsc->{'exonCount'},
		# example ucsc tables include a trailing comma in the lists, but why?
		join(",", @{$ucsc->{'exonStarts'}} ) . ',', 
		join(",", @{$ucsc->{'exonEnds'}} ) . ',',
		$ucsc->{'score'},
		$ucsc->{'name2'},
		$ucsc->{'cdsStartStat'},
		$ucsc->{'cdsEndStat'},
		join(",", @{$ucsc->{'exonFrames'}} ) . ',',
	) ) . "\n";
	
	$outfh->print($string);
	$count++; # increment global counter
}



sub collect_top_features {
	
	# the gff feature processor
	my $gff = shift; 
	
	# initialize
	my @top_features;
	my @orphan_features;
	my %loaded; # hash of loaded features
	
	# Collect the top features
	# we will use a global input filehandle, that way we can repeatedly call 
	# the subroutine and continue to subsequently read the file
	# we will continue to read the file until we either reach the file end
	# or we reach a close features directive (###)
	while (my $line = $in_fh->getline) {
		
		chomp $line;
		
		# check the gff version
		if ($line =~ /^##gff-version (\d)$/) {
			unless ($1 == 3) {
				die " Input GFF file is not version 3!\n" ;
			}
			next;
		}
		
		# skip comment lines
		next if $line =~ /^# /; 
		
		# close features directive line, all subfeatures have been loaded for 
		# this chromosome/scaffold
		last if $line =~ /^###/;
		
		# generate the SeqFeature object for this GFF line
		my $feature = Bio::SeqFeature::Generic->new();
			# sorry, we can't use SeqFeature::Lite, no frame method
		$gff->from_gff_string($feature, $line);
		
		# process the feature
		my ($id) = $feature->get_tag_values('ID');
		if (exists $loaded{$id}) {
			die " Feature ID '$id' occurs more than once in file!\n";
		} 
		else {
			$loaded{$id} = $feature;
		}
		
		# look for parents and children
		if ($feature->has_tag('Parent')) {
			# must be a child
			my ($parent) = $feature->get_tag_values('Parent');
			if (exists $loaded{$parent}) {
				# we've seen this id
				# associate the child with the parent
				$loaded{$parent}->add_SeqFeature($feature);
			}
			else {
				# can't find the parent, maybe not loaded yet?
				# put 'em in the orphanage
				push @orphan_features, $feature;
			}
		}
		else {
			# must be a parent
			push @top_features, $feature;
		}
	}
	# Finished loading the GFF lines (so far....)
	
	# check for orphans
	if (@orphan_features) {
		
		my $lost_count = 0;
		while (my $feature = shift @orphan_features) {
			
			# find the parent
			my ($parent) = $feature->get_tag_values('Parent');
			if (exists $loaded{$parent}) {
				# we've seen this id
				# associate the child with the parent
				$loaded{$parent}->add_SeqFeature($feature);
			}
			else {
				# can't find the parent
				# forget about them, just another statistic
				$lost_count++;
			}
		}
		
		# report
		if ($lost_count) {
			warn " $lost_count features could not be associated with" . 
				" reported parents!\n";
		}
	}
	
	# finished (for now)
	return @top_features;
}





__END__

=head1 NAME

gff3_to_ucsc_table.pl

=head1 SYNOPSIS

gff3_to_ucsc_table.pl [--options...] <filename>
  
  Options:
  --in <filename>
  --out <filename> 
  --help


=head1 OPTIONS

The command line flags and descriptions:

=over 4

=item --in <filename>

Specify the input GFF3 file. The file should not be compressed with gzip.

=item --out <filename>

Specify the output filename. By default it uses input file base name 
appened with '_refseq.txt'.

=item --help

Display this POD documentation.

=back

=head1 DESCRIPTION

This program will convert a GFF3 annotation file to a UCSC-style 
gene table, similar to that obtained through the UCSC Table Browser. 
Specifically, it matches the format of the refGene (RefSeq Genes) and 
ensGene (Ensembl Genes) tables. 

It will assemble the exon starts, stops, and frames from the defined 
transcript features in the GFF3 file. This assumes the standard 
parent->child relationship using the primary tags of 
gene -> mRNA -> [CDS, five_prime_utr, three_prime_utr]. 
Additional features (exon, start_codon, stop_codon, transcript) 
will be safely ignored. 

It will also process non-coding transcripts, including all non-coding 
RNAs; all subfeatures of non-coding RNAs will be considered as exons.

The cdsStartStat and cdsEndStat fields are populated depending on 
whether five- or three-prime UTRs exist; this may or may not reflect 
the actual status according to UCSC. 

The bin field is reserved for internal UCSC database use; it is 
automatically filled with a generic 0 in the output file.



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

