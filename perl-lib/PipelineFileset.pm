#
#	PipelineFileset.pm
#Thu Dec  2 15:24:49 CET 2010
#

{
	package Submitter;
	use Moose;
	use TempFileNames;

	has 'useQsub', is => 'ro', isa => 'Int', default => 0;
	has 'jidWaitList', is => 'rw', default => sub { [] };
	has 'jidFile', is => 'ro', isa => 'Str', default => sub {
		my $f = tempFileName("/tmp/qsubSubmitter_$ENV{USER}", undef, { doTouch => 1 });
		Log("jidFile: $f");
		return $f;
	};

	sub system { my ($self, $cmd, $logLevel, %opts) = @_;
		if ($self->useQsub) {
			my $wait = int(@{$self->jidWaitList})?
				"--waitForJids '". join(',', @{$self->jidWaitList}). "'": '';
			my $storeJids = defined($self->jidFile)? '--jid '. $self->jidFile: '';
			my $cmdFile;
			if (defined($opts{cmdAsFile})) {
				$cmdFile = $opts{cmdAsFile} eq ''
					? tempFileName("/tmp/qsubSubmitter_$ENV{USER}", undef, { doTouch => 1})
					: $opts{cmdAsFile};
				writeFile($cmdFile, $cmd);
			}
			$cmd = defined($opts{cmdAsFile})
				? "qsub.pl $wait $storeJids --cmdFromFile $cmdFile --"
				: "qsub.pl $wait $storeJids --unquote -- ". qs($cmd);
		}
		TempFileNames::System($cmd, $logLevel, undef, {%opts});
	}
	sub jids { my ($self) = @_;
		return $self->useQsub? [split("\n", readFile($self->jidFile))]: []
	}
	no Moose;
}

{
	package PipelineFileset;
	use Moose;
	use PropertyList;
	use TempFileNames;
	use Set;
	use Data::Dumper;

	extends 'Submitter';
	# object definition
	has 'specPath', is =>'ro',
		trigger => sub { my ($self, $path) = @_;
			$self->spec(propertyFromString(readFile($path)));
			$self->jidWaitList($self->spec()->{jids});
	};
	has 'o', is =>'ro';		# options
	has 'strata', is => 'ro', isa => 'Str', default => sub { [''] },
		trigger => sub { my ($self, $s) = @_;
			my @sl = split(/,/, $s);
			$self->strataList(!@sl? ['']: [@sl])
	};
	has 'strataList', is => 'rw', default => sub { [''] };
	has 'outputSpecFileName', is => 'ro', default => 'files.spec';
	has 'outputFileType', is => 'ro', isa => 'Str', default => 'generic';
	has 'outputPrefix', is => 'ro', isa => 'Str',
		default => sub { tempFileName('pipeline', '', { mkDir => 1, dontDelete => 1 }) };

	# object states
	has 'spec', is =>'rw';
	has 'outputDir', is =>'rw';
	has 'writefilespec', is => 'ro', default => 1;


	sub batchCommands { my ($self, $stratum) = @_;
		my @cmds = map {
			my $f = $_;
			my $sp = splitPathDict($f->{name});
			my $outputPath = $self->outputDir. '/'. $sp->{base}. "_$stratum";
			{
				cmd => "cat $f->{name}",
				file => { %$f, name => $outputPath }
			}
		} @{$self->spec->{files}};
		return @cmds;
	}
	sub iterateFiles { my ($self, $stratum) = @_;
		my @cmds = $self->batchCommands($stratum);
		Log(Dumper([@cmds]));
		$self->system($_->{cmd}, 4) foreach (@cmds);

		my $spec = {
			type => $self->outputFileType, files => [map { $_->{file} } @cmds],
			jids => $self->jids
		};
		return $spec;
	}
	sub prepareRun { my ($self) = @_;
	}

	sub run { my ($self) = @_;
		$self->prepareRun();
		my $s = $self->spec();
		# <p> defaults
		foreach my $stratum (@{$self->strataList}) {
			my $postf = @{$self->strataList} <= 1? '': "_$stratum";
			$self->outputDir($self->outputPrefix.$postf);
 			Mkpath($self->outputDir) if (! -e $self->outputDir && !$main::__doLogOnly);
 			my $so = $self->iterateFiles($stratum);
			# write output specification
			my $specpath = $self->outputDir. '/'. $self->outputSpecFileName;
			if ($self->writefilespec) {
				writeFile($specpath, stringFromProperty($so));
			} else {
				Log("Skipping writing filespec to ". $specpath, 4);
			}
		}
		

	}
	no Moose;
}

#
#	pipeline.pl classes
#

{	# abstract batch queueing class
	package BatchQueue;
	use Moose;

	# submit a command to the batch queue
	#	return hash with return code, jobid
	sub submit { die 'abstract method' }
	# query job ids (jids) currently queued
	sub queuedJobs { die 'abstract method' }
	no Moose;
}

{	# a synchronous batch queue using /bin/sh
	package BatchQueueSh;
	use Moose;
	extends 'BatchQueue';

	use TempFileNames;

	sub submit { my ($self, $cmd, $logLevel, %o) = @_;
		my $ret = TempFileNames::System($cmd, $logLevel, undef, {%o});
Log("Return code:$ret");
		return { return => $ret, jid => undef };
	}
	sub queuedJobs { return (); }
	no Moose;
}

{	# sun grid engine batch queueing class
	package BatchQueueSGE;
	use Moose;
	extends 'BatchQueue';

	use TempFileNames;

	has 'jidFile', is => 'ro', isa => 'Str', default => sub { 
		tempFileName("/tmp/sge_jidFile_$ENV{USER}") };

	# submit a command to the batch queue
	# o: options: waitJids
	#<i> implement jidReplace in qsub.pl
	sub submit { my ($self, $cmd, $logLevel, %o) = @_;
		$logLevel = 4 if (!defined($logLevel));
		my $wait = defined($o{waitJids}) && int(@{$o{waitJids}})?
			"--waitForJids '". join(',', @{$o{waitJids}}). "'": '';
		my $storeJids = defined($self->jidFile)? '--jidReplace '. $self->jidFile: '';
		$cmd = "qsub.pl $wait $storeJids --unquote -- ". qs($cmd);
		TempFileNames::System($cmd, $logLevel, undef, {%o});
		return { jid => defined($self->jidFile)? int(readFile($self->jidFile)): -1 };
	}
	# query job ids (jids) currently queued
	sub queuedJobs {
		my @jobs;
		my $xml = substr(Set::firstDef(`which xml 2>/dev/null`, `which xmlstarlet 2>/dev/null`), 0, -1);
		if (defined($xml)) {
			@jobs = (`qstat -u \\* -xml | $xml sel -t -m '//JB_job_number' -v 'text()' -o ' '`
				=~ m{(\d+)}sog);
		} else {
			my $jobs = TempFileNames::System("qstat -u '*' | tail -n+3 | cut -d ' ' -f 1 -",
				7, undef, { returnStdout => 'YES'})->{output};
			@jobs = split(/\n/, $jobs);
		}
		return @jobs;
	}
	no Moose;
}

{	# pipeline to perform one-by-one transformations of files
	package PipelineTransform;
	use Moose;
	use MooseX::UndefTolerant;
	use PropertyList;
	use TempFileNames;
	use Set;
	use Data::Dumper;

	# object definition
	has 'specPath', is =>'rw',
		trigger => sub { my ($self, $path) = @_;
			$self->spec(propertyFromString(readFile($path)));
			$self->jidWaitList($self->spec()->{jids});
	};
	has 'jidWaitList', is => 'rw', default => sub { [] };
	has 'jids', is => 'rw', isa => 'ArrayRef', default => sub { [] };
	has 'scheduler', is => 'ro', isa => 'BatchQueue';
	has 'strata', is => 'ro', isa => 'ArrayRef', default => sub { [] };
	has 'commandTemplate', is => 'ro', isa => 'Str';
	has 'commandPrepare', is => 'ro', isa => 'Str', default => '';
	has 'fileMeta', is => 'rw', default => sub { {} };
	has 'o', is => 'ro';		# options
	has 'outputSpecFileName', is => 'ro', default => 'files.spec';
	has 'outputFileType', is => 'ro', isa => 'Str', default => 'generic';
	has 'outputExtension', is => 'ro', isa => 'Str', default => 'txt';
	has 'outputDir', is => 'ro', isa => 'Str',
		default => sub { tempFileName('pipeline', '', { mkDir => 1, dontDelete => 1 }) };

	# object states
	has 'spec', is =>'rw';

	sub postfix { my ($self) = @_;
		return $self->outputExtension eq ''? '': ('.'. $self->outputExtension);
	}
	
	sub batchCommands { my ($self) = @_;
		my @cmds = map {
			my $f = $_;
			my $sp = splitPathDict($f->{name});
			my $strata = !defined($self->strata)? '': join('-', @{$self->strata});
			my $outputPath = $self->outputDir. '/'. $sp->{base}.
				($strata ne ''? "-$strata": $strata). $self->postfix;
			my %interp = (
				OUTPUT => $outputPath,
				INPUT_FILES => join(' ', map { qs($_->{file}) } @{$self->spec()->{files}}),
				INPUT => $f->{name},
				FILE_META => qs(stringFromProperty(firstDef($f, {})))
			);
			%interp = (%interp, (map { ( "META:$_", $f->{$_} ) } keys %$f));

			{
				cmd => mergeDictToString({ %interp }, $self->commandTemplate, { iterate => 'YES' }),
				file => { %{$self->fileMeta}, %$f, name => $outputPath }
			}
		} @{$self->spec->{files}};
		return @cmds;
	}
	sub iterateFiles { my ($self) = @_;
		my @cmds = $self->batchCommands();
		Log(Dumper([@cmds]));
		my @jids;
		push(@{$self->jids}, $self->scheduler->submit($_->{cmd}, 4,
			waitJids => $self->jidWaitList)->{jid}) foreach (@cmds);

		my $spec = {
			type => $self->outputFileType, files => [map { $_->{file} } @cmds],
			jids => [@{$self->jids}]
		};
		return $spec;
	}
	sub prepareRun { my ($self, $inputs, %o) = @_;
		# <p> handle pre-command
		return if ($self->commandPrepare eq '');
		# <p> collect all pre-requisites
		my @waitJids;
		push(@waitJids, @{propertyFromString(readFile($_))->{jids}})
			foreach (@$inputs);
		if ($self->o->{synchroneous_prepare}) {
			System($self->commandPrepare, 4);
			$self->jidWaitList([]);
		} else {
			my $jid = $self->scheduler->submit($self->commandPrepare, 4, waitJids => [@waitJids])->{jid};
			push(@{$self->jids}, $jid);
			$self->jidWaitList([$jid]);
		}
	}

	sub runInput { my ($self, $inputPath, %o) = @_;
		$self->specPath($inputPath);
		# <p> allow overwrites
		$self->prepareRun([$inputPath], %o);
		# <p> establish output directory
		Mkpath($self->outputDir) if (! -e $self->outputDir && !$main::__doLogOnly);
		# <p> schedule commands
		my $so = $self->iterateFiles();
		# write output specification
		writeFile($self->outputDir.'/'.$self->outputSpecFileName, stringFromProperty($so));
	}

	sub run { my ($self, @inputs) = @_;
		$self->runInput("$_/files.spec") foreach (@inputs);
	}

	no Moose;
}

{	# pipeline to perform one-by-one transformations of files
	package PipelineSummary;
	use Moose;
	use MooseX::UndefTolerant;
	use PropertyList;
	use TempFileNames;
	use Set;
	extends 'PipelineTransform';

	sub batchCommands { my ($self) = @_;
		my @files = @{$self->spec()->{files}};
		my $f = @files > 0? $files[0]: { name => 'genericSummary' };
		my $sp = splitPathDict($f->{name});
		my $strata = join('-', @$self->strata);
		my $outputPath = $self->outputDir. '/'. $sp->{base}.
			($strata ne ''? "-$strata": $strata). $self->postfix;
		my $cmd = {
			cmd => mergeDictToString({
				OUTPUT => $outputPath,
				INPUT_FILES => join(' ', map { qs($_->{file}) } @{$self->spec()->{files}}),
				INPUT => $self->specPath
			}, $self->commandTemplate, { iterate => 'YES' }),
			file => { %$f, name => $outputPath }
		};
		return ( $cmd );
	}

	no Moose;
}

1;
