#!/usr/bin/perl -w
#
# This script will find all the files that have the suffix for a 
# particular directory structure and replace (in place) and remove the suffix
# 
# Requires: 
#	sudo apt-get install libfile-find-rule-perl
# ###################################################################

$|++;

use strict;
use warnings;
use Getopt::Long;
use File::Copy;
use File::Find::Rule;
use File::Basename;

# ##############################
# Set path and delete IFS for security
# ##############################
$ENV{'PATH'} = '/usr/bin';
delete $ENV{'IFS'};


# ##############################
# GLOBAL Flags
# ##############################
my $TRUE = 1;
my $FALSE = 0;
my $SUCCESS = $TRUE;
my $FAIL = $FALSE;
my $EXIT_SUCCESS = 0; # Shell exit value 
my $EXIT_FAIL = 1; # Shell exit value 
my $ON = $TRUE;
my $OFF = $FALSE;
my $DEBUG = $OFF;
my $VERBOSE = $OFF;
my $PREVIEW = $OFF;
my $RECURSE = $OFF;
my $USAGE = $OFF;
my $AUTOESCAPE=$ON;
my $ESCAPE=$OFF;
my $ERRMSG = '';
my $FAILONWARN = $OFF;


# ##############################
# Variables
# ##############################
my $startDelimiter = '[%';
my $finalDelimiter = '%]';
my $replaceValueDefault = 'MISSING';
my $dataSrc = '';
my $targetDir = './';
my $targetSuffix = 'tt2';
my @targetDirs = ();
my %file2Process = ();
my %failures = ();
my $warningCount=0;
my $dataFileDirName='';

my %validSubActions = (
	'noescape'=>'noescape',
	'escape'=>'escape',
	'unknown'=>'noaction',
);

# ##############################
# Escape Mapping
#  
# reference: http://www.freeformatter.com/java-dotnet-escape.html
# ##############################
my %escapeMap = ( 
	'json'=> {'\\'=>'\\\\','"'=>'\"' },
	'js'=> {'\\'=>'\\\\','"'=>'\"' },
	'coffee'=> {'\\'=>'\\\\','"'=>'\"' },
	'properties'=> {'\\'=>'\\\\','"'=>'\"' },
	'xml'=> {"'"=>'&apos;','"'=>'&quot;','&'=>'&amp;','<'=>'&lt;','>'=>'&gt;' },
	'html'=> {"'"=>'&apos;','"'=>'&quot;','&'=>'&amp;','<'=>'&lt;','>'=>'&gt;' },
	'csv'=> {'"'=>'""'},
	'sql'=> {"'"=>"''"},
	'ini'=> {'\\'=>'\\\\',';'=>'\\;','#'=>'\\#','='=>'\\=',':'=>'\\:' },
);

# ##############################
# Local escape syntax
# [% escape:KEY=REPLACEVAL %]
# ##############################

my $t_autoescape;

# ##############################
# Environment Variables
# ##############################
if(defined($ENV{'TEMPLATE_DATA'}) ){
	$dataSrc=$ENV{'TEMPLATE_DATA'};
}

# ##############################
# Process Command line args
# ##############################
GetOptions (
	'usage' => \$USAGE,
	'help' => \$USAGE,
	'dir=s' => \$targetDir,
	'suffix=s' => \$targetSuffix,
	'autoescape=s' => \$t_autoescape,
	'failonwarn' => \$FAILONWARN,
	'verbose' => \$VERBOSE,
	'preview' => \$PREVIEW,
	'debug' => \$DEBUG,
	'data=s' => \$dataSrc
	) or die("Error in command line arguements\n");
if($USAGE){
	_usage();
	exit($EXIT_SUCCESS);
}
if(defined($t_autoescape) && $t_autoescape =~ /^(off|false)$/i){
	$AUTOESCAPE=$OFF;
}

_logWarn(level=>'debug',msg=>"DEBUG: $DEBUG") if($DEBUG);
_logWarn(level=>'debug',msg=>"VERBOSE: $VERBOSE") if($DEBUG);
_logWarn(level=>'debug',msg=>"suffix: $targetSuffix") if($DEBUG);
_logWarn(level=>'debug',msg=>"data: $dataSrc") if($DEBUG);

unless(-e $dataSrc){
	$failures{'data'} = "File ($dataSrc) does not exist.";
}
$dataFileDirName=dirname($dataSrc);

foreach my $tDir (split(/\s*,\s*/,$targetDir)){
	if(-d $tDir){
		_logWarn(level=>'debug',msg=>"Dir: $tDir added") if($DEBUG);
		push @targetDirs, $tDir;		
	}
}
if(scalar keys %failures){
	foreach my $failureKey (sort keys %failures){
		_logWarn(level=>'error',msg=>"$failureKey: $failures{$failureKey}");
	}
	_logWarn(level=>'error',msg=>"Too Many Failures to continue");
	exit(1);
}

if(main() == $SUCCESS){
	if($FAILONWARN && $warningCount){
		exit($EXIT_FAIL);
	}
	exit($EXIT_SUCCESS);
}
exit($EXIT_FAIL);


# ###################################################################
# define the subroutines
# ###################################################################
# ##############################
# main {{{
# ##############################
sub main {
	my %replaceMap = _readData('file'=>$dataSrc);
	if($DEBUG){
		foreach my $rekey (sort keys %replaceMap){
			_logWarn(level=>'debug',msg=>"K: '$rekey' V: '$replaceMap{$rekey}'");
		}
	}
	my @files2process = findFiles();
	if($DEBUG||$PREVIEW){
		foreach my $f (sort @files2process){
			_logWarn(level=>'preview',msg=>"processing file: $f");
		}
	}
	if(processFiles(data=>\%replaceMap,files=>\@files2process)){
		return $SUCCESS;
	}
	return $FAIL;
} # End main }}}
# ##############################
# _usage {{{
# ##############################
sub _usage {
	print << "EOP";

	Usage: $0 -help | -usage
               $0 -data <file> [-dir <directory>] [-debug] [-verbose]
        
        autoescape <opt>   - Set AutoEscape (off|false) default <on>
        data <file>        - Set the datafile to <file> (or set ENV TEMPLATE_DATA)
        debug              - Turn DEBUG on
        dir <directory>    - Start looking for the template in this <dir> (default ./)
	failonwarn         - Exit a nonzero if there are any warnings during processing
        help               - Display this usage
        verbose            - Turn VERBOSE mode. 
                
EOP
        return $TRUE;


} # End _usage }}}
# ##############################
# _logWarn {{{
# ##############################
sub _logWarn {
        my %args = @_;
        my $this_msg = $args{'msg'};
        my $this_level = defined($args{'level'}) ? $args{'level'} : 'info';
        my $now = scalar(localtime);
        my $PID = $$;
        warn "[$now] [$PID] [$this_level] $this_msg\n";
        return $TRUE;
} # End _logWarn }}}

# ##############################
# _readData {{{
# ##############################
sub _readData {
	my %args = @_;
	if(! -e $args{'file'}){
		return ;
	}
	my %dataValues = ();
	my @needsReplaced = ();
	open (DATA, "<$args{'file'}") or die($!);
	while (<DATA>){	
		my $line = $_;
		chomp($line);
		next if($line =~ /^\s*\#.*$/); # Skip lines with only comments
		next if($line =~ /^\s*$/); # Skip empty lines 
		if($line=~/^\s*(.+?)\s*=\s*(['"]?)(.*)(\2)/){
			my $key = $1;
			my $val = $3;
			if($val =~ /\$\{(.*?)\}/ ){
				my $subfield = $1;
				if(defined($dataValues{$subfield})){
					my $subdata = $dataValues{$subfield};
					$val =~ s/\$\{$subfield\}/$subdata/g;
					_logWarn(level=>'debug',msg=>"Replaced \${$subfield} with $subdata") if($DEBUG);
				}else{
					_logWarn(level=>'preview',msg=>"Have not seen Var: \${$subfield}") if($DEBUG);
					#push @needsReplaced,$key;
				}
			}
			if($val =~ /\$\{(.*?)\}/ ){
				push @needsReplaced,$key;
			}
			$dataValues{$key}=$val;
			
		}else{
		}
	}
	close DATA;
	#Final Pass
	my $lastVal = '';
	foreach my $thiskey (@needsReplaced){
		_logWarn(level=>'debug',msg=>"Fixing $thiskey") if($DEBUG);
		my $val = $dataValues{$thiskey};
		if($thiskey eq $lastVal){
			last; 
		}else{
			$lastVal = $thiskey;
		}	
		if($val =~ /\$\{(.*?)\}/ ){
			my $subfield = $1;
			if(defined($dataValues{$subfield})){
				my $subdata = $dataValues{$subfield};
				$val =~ s/\$\{$subfield\}/$subdata/g;
			}else{ # spit out a warning of a variable that does not exist
				my $msg = "There appears to be a variable in the config file that is not defined: '\${$subfield}'";
				_logWarn(level=>'warn',msg=>"$msg");
				$warningCount++;
			}
			$dataValues{$thiskey}=$val;
			if($val =~ /\$\{(.*?)\}/ ){
				push @needsReplaced,$thiskey;
			}
		}
	}
	return %dataValues;
} # End _readData }}}

# ##############################
# findFiles {{{
# ##############################
sub findFiles  {
	my %args = @_;
	my @files = File::Find::Rule->file()
				->name('*.'.$targetSuffix)
				->in(@targetDirs);
	return @files;
} # End findFiles }}}

# ##############################
# processFiles {{{
# ##############################
sub processFiles {
	my %args = @_;
	my @required_args = qw(data files);
	my %missing_arg=();
	foreach my $req_arg (@required_args){
		if(!defined($args{$req_arg})){
			_logWarn(level=>'error',msg=>"Missing required arg: $req_arg");
			$missing_arg{$req_arg}++;
		}
	}
	if(scalar keys %missing_arg){
		return $FAIL;	
	}
	my %configValue=%{$args{'data'}};

	foreach my $file (sort @{$args{'files'}}){
		my $srcFile = $file;
		my ($dstFile) = $srcFile =~ m/^(.*).$targetSuffix$/;
		my ($dstSuffix) = $dstFile =~ /\.([^.]+)$/;
		my $dstFile_new = $dstFile . '.new';
		my $dstFile_bak = $dstFile . '.bak';
		$dstSuffix = '' if(! defined($dstSuffix) );
		my %thisEscapeMap = ();
		_logWarn(level=>'verbose',msg=>"processing: '$dstFile'") if($VERBOSE);
		_logWarn(level=>'debug',msg=>"srcFile: '$srcFile'") if($DEBUG);
		_logWarn(level=>'debug',msg=>"dstFile: '$dstFile'") if($DEBUG);
		
		if($AUTOESCAPE && defined($escapeMap{$dstSuffix}) ){
			_logWarn(level=>'debug',msg=>"VALID FILE SUFFIX DETECTED($dstSuffix): '$dstFile'") if($DEBUG);
			# Lets load up the replacements 
			$ESCAPE=$ON;
			%thisEscapeMap = %{$escapeMap{$dstSuffix}};
		}
		if(-e $dstFile){
			copy($dstFile,$dstFile_bak); 
		}
		open(TEMPLATE,"<$srcFile") or $ERRMSG=$!;
		open(OUTFILE,">$dstFile_new") or $ERRMSG=$!;
		my $linecount=0;
		my $fileToCopy = '';
		my $match_line=quotemeta($startDelimiter) . '\s+(.*?)\s+' . quotemeta($finalDelimiter);
		my $match_escape_def='^\s*'.quotemeta($startDelimiter) . '\s+escape:(.*?)=(.*?)\s+' . quotemeta($finalDelimiter) .'\s*$';
		my $match_filecopy_def='^\s*'.quotemeta($startDelimiter) . '\s+filecopy:(.*?)\s+' . quotemeta($finalDelimiter) .'\s*$';
		while(<TEMPLATE>){
			$linecount++;
			my $line = $_;
			chomp($line);
			my $newline=$line;
			#while($line =~ m/$startDelimiter\s+(.*?)\s+$finalDelimiter/g){
			if($line =~ /$match_escape_def/){
				my $key = $1;
				my $val = $2;
				$thisEscapeMap{$key}=$val;
				$ESCAPE=$ON;
				next;
			}
			if($line =~ /$match_filecopy_def/){
				my $file_key = $1;		
				if(defined($configValue{$file_key})){
					$fileToCopy=$configValue{$file_key};
				}else{
					_logWarn(level=>'warn',msg=>"($dstFile:$linecount) FileToCopy ERROR '$file_key' ") ;
					_logWarn(level=>'warn',msg=>"($dstFile:$linecount) Missing value in config: '$file_key' ") ;
					$warningCount++;
				}
				next;
			}
			while($line =~ m/$match_line/g){
				my $thisVarEscape = $ESCAPE;      # This is used to escape or not escape a single replacement 
			  	my $replace_key = $1;
			  	my $replace_searchkey = $replace_key;
				chomp($replace_key);
				if($replace_key =~ /([a-z]+):(.+)$/) {
					my $want_subaction = $1;
					my $want_replace_key = $2;
					my $subaction = (defined($validSubActions{$want_subaction})) ? 
							$validSubActions{$want_subaction} :
							$validSubActions{'unknown'}
							;
			  		$replace_searchkey = $want_replace_key;
					if($subaction eq 'noescape' ){
						$thisVarEscape = $OFF;
					}elsif($subaction eq 'escape'){
						$thisVarEscape = $ON;
					}else{ # This is a noaction
					       # Do Nothing
					}

				}
				my $replace_value = $replaceValueDefault;
				if(defined($configValue{$replace_searchkey})){
					_logWarn(level=>'debug',msg=>"($dstFile:$linecount) Replacing: '$replace_key' with '$configValue{$replace_searchkey}'") if($DEBUG);
					$replace_value = $configValue{$replace_searchkey};
				}else{
					_logWarn(level=>'warn',msg=>"($dstFile:$linecount) Missing value in config: '$replace_key' ") ;
					$warningCount++;
				}
				my $replace_value_qm = quotemeta($replace_value);
				my $match_replace= quotemeta($startDelimiter) .'\s+'. $replace_key.'\s+' . quotemeta($finalDelimiter);
				my $match_replace_qm =quotemeta($startDelimiter) . '\s+' . quotemeta($replace_key) . '\s+'.  quotemeta($finalDelimiter);
				if($DEBUG) {
					if($newline =~ /$match_replace/){
						_logWarn(level=>'debug',msg=>"Found a match for '$match_replace' in '$newline'") ;
						#$newline =~ s/$match_replace/$replace_value/;
	
					}
					if($newline =~ /$match_replace_qm/){
						_logWarn(level=>'debug',msg=>"(QM) Found a match for '$match_replace' in '$newline'") if($DEBUG);
						#$newline =~ s/$match_replace_qm/$replace_value/;
					}
				}
				if($thisVarEscape){	
					$replace_value = _escape($replace_value,  \%thisEscapeMap );
				}
				$newline =~ s/$match_replace_qm/$replace_value/;
			}
			print OUTFILE "$newline\n";
		}
		close OUTFILE;
		close TEMPLATE;
		if($linecount==1 && $fileToCopy ){
			my $fullPathFileToCopy = $dataFileDirName .'/' . $fileToCopy;
			if(-e $fullPathFileToCopy ){
				copy($fullPathFileToCopy,$dstFile_new);
				_logWarn(level=>'verbose',msg=>"Copy $fullPathFileToCopy to $dstFile") if($VERBOSE);
			}else{
				_logWarn(level=>'warn',msg=>"FileToCopy: File does not exist. '$fileToCopy' ") ;
				$warningCount++;
			}
		
		}
		copy($dstFile,$dstFile_bak) if(-e $dstFile);
		copy($dstFile_new,$dstFile) if(-e $dstFile_new);
		unlink($dstFile_new) if(-e $dstFile_new && -e $dstFile);
	}
	return $SUCCESS;
} # End processFiles }}}

# ##############################
#  _escape
# ##############################
sub  _escape {
	my $string_in = shift;
	my $replacemap = shift;
	#_logWarn(level=>'debug',msg=>"IN ESCAPE -  STRING: '$string_in' ") if($DEBUG);
	my @chars=split(//,$string_in);
	_logWarn(level=>'debug',msg=>"CHARS (before): '". join('',@chars) . "' ") if($DEBUG);
	for( my $i=0;$i<scalar(@chars);$i++){
		my $thisChar=$chars[$i];
		$chars[$i]=${$replacemap}{$thisChar} if(defined(${$replacemap}{$thisChar}));	
	}
	_logWarn(level=>'debug',msg=>"CHARS  (after): '".join('',@chars)."' ") if($DEBUG);
	return join('',@chars);
}
# ##############################

__END__
