#!/usr/bin/env perl
#
# getOfflineBarPackages.pl
#
# Perl script retrieving all the files required to install the Beyond All Reason
# game offline. Files can be imported both from a local installation of the game
# and from official online packages. Versions of game components can be
# customized.
#
# Copyright (C) 2024  Yann Riou <yaribzh@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
#

use warnings;
use strict;

use feature 'state';

use Cwd;
use File::Copy 'cp';
use File::Path 'mkpath';
use File::Spec::Functions qw'catdir catfile devnull file_name_is_absolute';
use File::Temp ();
use FindBin;
use Getopt::Long 2.3203 qw':config no_auto_abbrev no_getopt_compat bundling no_ignore_case';
use HTTP::Tiny;
use IO::Uncompress::Gunzip '$GunzipError';
use JSON::PP 'decode_json';
use List::Util qw'first all any';
use Storable 'dclone';

#############
# CONSTANTS #
#############

use constant {
  MSWIN32 => $^O eq 'MSWin32',
  SPADS_REPOSITORY_URL => 'http://planetspads.free.fr/spads/repository/',
  BAR_DOWNLOAD_URL => 'https://www.beyondallreason.info/download',
  BAR_PRD_BASE_URL => 'https://raw.githubusercontent.com/beyond-all-reason/spring-launcher/master/bin/',
  BAR_GITHUB_REPOSITORY => 'beyond-all-reason/spring',
  BAR_LAUNCHER_CONFIG_URL => 'https://launcher-config.beyondallreason.dev/config.json',
  BAR_LAUNCHER_PACKAGE_ID_LINUX => 'manual-linux',
  BAR_LAUNCHER_PACKAGE_ID_WINDOWS => 'manual-win',
  BAR_MAPS_INVENTORY_URL => 'https://maps-metadata.beyondallreason.dev/latest/live_maps.validated.json',
};

my $VERSION='0.10';
my $BAR_DOWNLOAD_BASE_URL='https://github.com/beyond-all-reason/BYAR-Chobby/releases/download/';
my @BAR_LAUNCHER_CFG_SORT_ORDER=qw'
  title
  log_upload_url
  error_suffix
  setups
    package
      id
      display
      platform
    config_url
    env_variables
      PRD_HTTP_SEARCH_URL
      PRD_RAPID_USE_STREAMER
      PRD_RAPID_REPO_MASTER
    silent
    auto_download
    downloads
      games
      resources
        url
        destination
        extract
        optional
    no_start_script
    no_downloads
    logs_s3_bucket
    launch
      start_args
      engine
      springsettings
  links
  default_springsettings
    ';
my %BAR_LAUNCHER_CFG_FIELD_IDX;
map {$BAR_LAUNCHER_CFG_FIELD_IDX{$BAR_LAUNCHER_CFG_SORT_ORDER[$_]}=$_} (0..$#BAR_LAUNCHER_CFG_SORT_ORDER);

####################
# GLOBAL VARIABLES #
####################

my %opt;                 # command line options
my $outDir;              # absolute path of main output directory
my $dataOutDir;          # absolute path of data output directory
my $defaultLocalDataDir; # default local (source) data directory
my %tasks=(installer => 1, engine => 1, game => 1, chobby => 1, maps => 0, launcher => 1); # tasks to process
my $engineSubdir;        # versionned engine subdirectory (e.g. "105.1.1-2303-g5f26a29 bar")
my %engineDlUrls;        # engine download URLs, by operating system ("windows" and "linux")
my $gameRapidVersion;    # game rapid tag or name
my $chobbyRapidVersion;  # chobby rapid tag or name

#############
# FUNCTIONS #
#############

sub fatalError { die "[ERROR] $_[0]\n" }
sub printWarning { print "[WARNING] $_[0]\n"; return }
sub fatalOrWarn { return printWarning($_[0]) if($_[1]); fatalError($_[0]) }
sub badUsage { warn $_[0]."\n" if(defined $_[0]); die "Invalid usage (see --help).\n" };

sub processCmdLineOptions {
  my @incompatibleOptions=(
    ['linux','windows'],
    ['maps','maps-local'],
    ['tasks','disable'],
      );
  map {badUsage("Only one command line option allowed among \"--$_->[0]\" and \"--$_->[1]\".") if(defined $opt{$_->[0]} && defined $opt{$_->[1]})} @incompatibleOptions;

  foreach my $singleOption (qw'help version') {
    badUsage("The \"--$singleOption\" command line option cannot be used with other options.")
        if($opt{$singleOption} && keys %opt > 1);
  }

  if($opt{help}) {
    print <<EOH;

Usage:
  $FindBin::Script [options]
    
    Options:
      -h,--help                : print usage
      -v,--version             : print version
      -V,--verbose             : use verbose output
      -t,--tasks <tasks>       : comma-separated list of tasks to process
                                 (installer,engine,game,chobby,maps,launcher)
      -d,--disable <tasks>     : comma-separated list of tasks to disable
      -e,--engine <version>    : specify the engine version to retrieve
                                 (default: version from launcher config file)
      -E,--engine-local [dir]  : use local data directory to retrieve engine
      -g,--game <tagOrName>    : specify the game version to retrieve
                                 (default: "byar:test")
      -G,--game-local [dir]    : use local data directory to retrieve game
      -c,--chobby <tagOrName>  : specify the chobby version to retrieve
                                 (default: "byar-chobby:test")
      -C,--chobby-local [dir]  : use local data directory to retrieve chobby
      -m,--maps [dir]          : retrieve all Beyond All Reason maps
      -M,--maps-local [dir]    : retrieve maps from local data directory only
      -L,--local-datadir [dir] : specify local data directory
      -l,--linux               : skip Windows-specific packages
      -w,--windows             : skip Linux-specific packages
      -o,--output <dir>        : use a custom output directory
                                 (default: "BAR-offline_YYYYMMDD-hhmmss")
      -f,--force               : ignore already existing output directory
EOH
    print "\n" unless(MSWIN32);
    exit 0;
  }

  if($opt{version}) {
    print "getOfflineBarPackages v$VERSION\n";
    exit 0;
  }

  $tasks{maps}=1 if(defined $opt{maps} || defined $opt{'maps-local'});
  if(defined $opt{tasks}) {
    my @optTasks=split(',',$opt{tasks});
    my %newTasks;
    foreach my $task (@optTasks) {
      my $fullTask = first {index($_,lc($task)) == 0} (keys %tasks);
      fatalError("Invalid task \"$task\" in tasks list declaration")
          unless(defined $fullTask);
      fatalError("Duplicate task \"$fullTask\" in tasks list declaration")
          if(exists $newTasks{$fullTask});
      $newTasks{$fullTask}=1;
    }
    map {$newTasks{$_}//=0} (keys %tasks);
    %tasks=%newTasks;
  }
  if(defined $opt{disable}) {
    my @disabledTasks=split(',',$opt{disable});
    my %processedDisabledTasks;
    foreach my $disabledTask (@disabledTasks) {
      my $fullTask = first {index($_,lc($disabledTask)) == 0} (keys %tasks);
      fatalError("Invalid task \"$disabledTask\" in disabled tasks list declaration")
          unless(defined $fullTask);
      fatalError("Duplicate task \"$fullTask\" in disabled tasks list declaration")
          if(exists $processedDisabledTasks{$fullTask});
      $processedDisabledTasks{$fullTask}=1;
      $tasks{$fullTask}=0;
    }
  }
  fatalError('All tasks are disabled') unless(any {$tasks{$_}} (keys %tasks));

  if($tasks{maps}) {
    fatalError('The maps retrieval task requires the "--maps" or "--maps-local" command line option')
        unless(any {defined $opt{$_}} (qw'maps maps-local'));
  }else{
    fatalError('The "--maps" and "--maps-local" command line options cannot be used when the maps retrieval task is disabled')
        if(any {defined $opt{$_}} (qw'maps maps-local'));
  }

  fatalError('Cannot generate customized launcher configuration: need at least the engine retrieval task to be enabled or the --engine command line option to specify the required engine version')
      if($tasks{launcher} && ! $tasks{engine} && ! $opt{engine});
  
  if(defined $opt{output}) {
    $outDir=$opt{output};
  }else{
    my @time = localtime();
    $time[4]++;
    @time = map(sprintf('%02d',$_),@time);
    $outDir='BAR-offline_'.($time[5]+1900).$time[4].$time[3].'-'.$time[2].$time[1].$time[0];
  }
  $outDir=catdir(cwd(),$outDir) unless(file_name_is_absolute($outDir));
  $dataOutDir=catdir($outDir,'data');
  
  foreach my $dir ($outDir,$dataOutDir,$opt{linux} ? () : catdir($outDir,'data-windows'),$opt{windows} ? () : catdir($outDir,'data-linux')) {
    if(-e $dir) {
      fatalError("Output path \"$dir\" already exists and is NOT a directory") unless(-d $dir);
      fatalError("Output directory \"$dir\" already exists and is NOT readable") unless(-r $dir);
      fatalError("Output directory \"$dir\" already exists and is NOT writable") unless(-w _);
      fatalError("Output directory \"$dir\" already exists and is NOT reachable") unless(-x _);
      fatalError("Output directory \"$dir\" already exists (use --force or -f to force)") unless($opt{force});
    }else{
      createDir($dir,'output directory');
    }
  }

  if(defined $opt{'local-datadir'} && $opt{'local-datadir'} ne '') {
    $defaultLocalDataDir=$opt{'local-datadir'};
  }else{
    my @potentialDataDirs;
    if(MSWIN32) {
      require Win32;
      @potentialDataDirs = map {catdir($_,'Beyond-All-Reason','data')} (
        catdir(Win32::GetFolderPath(Win32::CSIDL_LOCAL_APPDATA()),'Programs'),
        Win32::GetFolderPath(Win32::CSIDL_PROGRAM_FILES()),
      );
    }else{
      @potentialDataDirs = map {catdir($_,'Beyond All Reason')} (
        catdir($ENV{HOME},'Documents'),
        $ENV{XDG_STATE_HOME}//catdir($ENV{HOME},'.local','state'),
      );
    }
    foreach my $potentialDataDir (@potentialDataDirs) {
      if(-d $potentialDataDir) {
        $defaultLocalDataDir=$potentialDataDir;
        last;
      }
    }
    if(defined $defaultLocalDataDir) {
      $opt{'local-datadir'}=$defaultLocalDataDir if(defined $opt{'local-datadir'});
    }else{
      my @localDataOptsWithoutDir = grep {defined $opt{"$_-local"} && $opt{"$_-local"} eq ''} (qw'engine game chobby maps');
      fatalError('Could not auto-detect local data directory for command line option'.(@localDataOptsWithoutDir>1?'s':'').' "'.join('", "',map {"--$_-local"} @localDataOptsWithoutDir).'" (please specify local data directory manually)')
          if(@localDataOptsWithoutDir);
      fatalError('Could not auto-detect local data directory for command line option "--local-datadir" (please specify local data directory manually)')
          if(defined $opt{'local-datadir'});
    }
  }
  
  checkExistingDirectory($opt{'local-datadir'},'local data directory') if(defined $opt{'local-datadir'});
  map {checkExistingDirectory($opt{"$_-local"},"local $_ data directory") if(defined $opt{"$_-local"} && $opt{"$_-local"} ne '')} (qw'engine game chobby maps');

  $gameRapidVersion=$opt{game}//'byar:test';
  $chobbyRapidVersion=$opt{chobby}//'byar-chobby:test';
}

sub createDir {
  my ($path,$dirName)=@_;
  $dirName//='directory';
  eval {mkpath($path)};
  if($@) {
    chomp($@);
    fatalError("Failed to create $dirName \"$path\": $@");
  }
}

sub checkExistingDirectory {
  my ($path,$dirName,$checkWrite)=@_;
  fatalError("Specified path for $dirName \"$path\" does NOT exist")
      unless(-e $path);
  fatalError("Specified path for $dirName \"$path\" is NOT a directory")
      unless(-d $path);
  $dirName=ucfirst($dirName);
  fatalError("$dirName \"$path\" is NOT readable")
      unless(-r $path);
  fatalError("$dirName \"$path\" is NOT reachable")
      unless(-x _);
  fatalError("$dirName \"$path\" is NOT writable")
      if($checkWrite && ! -w _);
}

sub getHttpErrMsg {
  my $httpRes=shift;
  if($httpRes->{status} == 599) {
    my $errMsg=$httpRes->{content};
    chomp($errMsg);
    return $errMsg;
  }
  return "HTTP $httpRes->{status} $httpRes->{reason}";
}

sub getHttpTiny {
  state $httpTiny;
  return $httpTiny if(defined $httpTiny);
  $httpTiny=HTTP::Tiny->new(timeout => 10);
  return $httpTiny;
}

sub downloadFile {
  my ($url,$dest,$description)=@_;
  my $httpRes=getHttpTiny()->mirror($url,$dest);
  fatalError("Failed to download $description from \"$url\" to \"$dest\": ".getHttpErrMsg($httpRes))
      unless($httpRes->{success} && -f $dest && -s $dest);
}

sub httpGet {
  my ($url,$description,$nonFatal,$r_headers)=@_;
  my $httpRes = defined $r_headers ? getHttpTiny()->get($url,$r_headers) : getHttpTiny()->get($url);
  return fatalOrWarn("Failed to retrieve $description from \"$url\": ".getHttpErrMsg($httpRes),$nonFatal)
      unless($httpRes->{success});
  return $httpRes->{content};
}

sub getTmpDir {
  state $tmpDir;
  return $tmpDir if(defined $tmpDir);
  $tmpDir=File::Temp::tempdir(CLEANUP => 1);
  return $tmpDir;
}

sub get7zipBin {
  state $sevenZipBin;
  return $sevenZipBin if(defined $sevenZipBin);
  my $sevenZipVersion = MSWIN32 ? '9.20' : '16.2';
  my $sevenZipName = '7za-'.$sevenZipVersion.(MSWIN32 ? '.exe' : '');
  $sevenZipBin=catfile(getTmpDir(),$sevenZipName);
  my $sevenZipUrl=SPADS_REPOSITORY_URL.$sevenZipName;
  if($opt{verbose}) {
    print "> Downloading 7-Zip binary [$sevenZipVersion]\n";
    print "  from: $sevenZipUrl\n";
    print "  to: $sevenZipBin\n";
  }
  downloadFile($sevenZipUrl,$sevenZipBin,'7-Zip binary');
  chmod(0755,$sevenZipBin) unless(MSWIN32);
  return $sevenZipBin;
}

sub decodeJson {
  my ($r_jsonString,$description,$requiredArrayField,$nonFatal)=@_;
  my $r_json;
  eval { $r_json=decode_json($$r_jsonString) };
  if(! defined $r_json) {
    my $jsonDecodeError='unknown error';
    if($@) {
      chomp($@);
      $jsonDecodeError=$@;
    }
    return fatalOrWarn("Failed to parse $description: $jsonDecodeError",$nonFatal);
  }
  return fatalOrWarn("Cannot find \"$requiredArrayField\" array in $description",$nonFatal)
      unless(ref $r_json eq 'HASH' && ref $r_json->{$requiredArrayField} eq 'ARRAY');
  return $r_json;
}

sub escapeWin32Parameter {
  my $arg = shift;
  $arg =~ s/(\\*)"/$1$1\\"/g;
  if($arg =~ /[ \t\(]/) {
    $arg =~ s/(\\*)$/$1$1/;
    $arg = "\"$arg\"";
  }
  return $arg;
}

sub systemNoOutput {
  my ($program,@params)=@_;
  my @args=($program,@params);
  my ($exitCode,$exitErr);
  if(MSWIN32) {
    system(join(' ',(map {escapeWin32Parameter($_)} @args),'>'.devnull(),'2>&1'));
    ($exitCode,$exitErr)=($?,$!);
  }else{
    open(my $previousStdout,'>&',\*STDOUT);
    open(my $previousStderr,'>&',\*STDERR);
    open(STDOUT,'>',devnull());
    open(STDERR,'>&',\*STDOUT);
    system {$program} (@args);
    ($exitCode,$exitErr)=($?,$!);
    open(STDOUT,'>&',$previousStdout);
    open(STDERR,'>&',$previousStderr);
  }
  return (undef,$exitErr) if($exitCode == -1);
  return (undef,'child process interrupted by signal '.($exitCode & 127).($exitCode & 128 ? ', with coredump' : '')) if($exitCode & 127);
  return ($exitCode >> 8);
}

sub uncompress7zipFile {
  my ($archiveFile,$destDir,$description)=@_;
  my $sZipBin=get7zipBin();
  print '> Extracting '.$description."\n";
  if($opt{verbose}) {
    print "  from: $archiveFile\n";
    print "  to: $destDir\n";
  }
  my $previousEnvLangValue=$ENV{LC_ALL};
  $ENV{LC_ALL}='C' unless(MSWIN32);
  my ($exitCode,$errorMsg)=systemNoOutput($sZipBin,'x','-y',"-o$destDir",$archiveFile);
  if(! MSWIN32) {
    if(defined $previousEnvLangValue) {
      $ENV{LC_ALL}=$previousEnvLangValue;
    }else{
      delete $ENV{LC_ALL};
    }
  }
  my $failReason;
  if(defined $errorMsg) {
    $failReason=", error while running 7zip ($errorMsg)";
  }elsif($exitCode != 0) {
    $failReason=" (7zip exit code: $exitCode)";
  }
  fatalError("Failed to extract \"$archiveFile\" to \"$destDir\"$failReason")
      if(defined $failReason);
}

sub getBarLauncherConfig {
  my $dataDir=shift//'';
  state %barLauncherConfigCache;
  return $barLauncherConfigCache{$dataDir} if(exists $barLauncherConfigCache{$dataDir});
  $barLauncherConfigCache{$dataDir}=undef;
  if($dataDir eq '') {
    my $launcherCfgJson=httpGet(BAR_LAUNCHER_CONFIG_URL,'Beyond All Reason launcher configuration',1)
        or return undef;
    $barLauncherConfigCache{''}=decodeJson(\$launcherCfgJson,'online Beyond All Reason launcher JSON configuration file','setups',1);
  }else{
    my $launcherConfFile=catfile($dataDir,'config.json');
    return printWarning("Beyond All Reason launcher configuration not found in local data directory \"$dataDir\"")
        unless(-f $launcherConfFile);
    open(my $launcherConfFh,'<',$launcherConfFile)
        or return printWarning("Failed to open launcher configuration file \"$launcherConfFile\" for reading ($!)");
    my $launcherConfJson;
    {
      local $/=undef;
      $launcherConfJson=<$launcherConfFh>;
    }
    close($launcherConfFh);
    $barLauncherConfigCache{$dataDir}=decodeJson(\$launcherConfJson,'local Beyond All Reason launcher JSON configuration file','setups',1);
  }
  return $barLauncherConfigCache{$dataDir};
}

sub retrieveEngineInfoFromBarLauncherConfig {
  my $dataDir=shift;
  my $r_launcherConfig=getBarLauncherConfig($dataDir);
  my $type = defined $dataDir ? 'local' : 'online';
  fatalError("Cannot retrieve engine configuration data from $type Beyond All Reason launcher configuration")
      unless(defined $r_launcherConfig);
  my %idFilters = (
    BAR_LAUNCHER_PACKAGE_ID_WINDOWS() => 'windows',
    BAR_LAUNCHER_PACKAGE_ID_LINUX() => 'linux',
      );
  foreach my $r_barSetup (@{$r_launcherConfig->{setups}}) {
    next unless(ref $r_barSetup eq 'HASH' && ref $r_barSetup->{package} eq 'HASH');
    my $r_barPackage=$r_barSetup->{package};
    next unless(defined $r_barPackage->{id} && ref $r_barPackage->{id} eq '' && exists $idFilters{$r_barPackage->{id}});
    fatalError("Cannot find download data for \"$r_barPackage->{id}\" setup package in $type Beyond All Reason launcher JSON configuration file")
        unless(ref $r_barSetup->{downloads} eq 'HASH' && ref $r_barSetup->{downloads}{resources} eq 'ARRAY');
    my $r_engineDlInfo = first {ref $_ eq 'HASH' && defined $_->{url} && ref $_->{url} eq '' && substr($_->{url},0,4) eq 'http' && $_->{url} =~ /\/[^\/]+$/
                                && defined $_->{destination} && ref $_->{destination} eq '' && substr($_->{destination},0,7) eq 'engine/'} @{$r_barSetup->{downloads}{resources}};
    fatalError("Cannot find engine download information for \"$r_barPackage->{id}\" setup package in $type Beyond All Reason launcher JSON configuration file")
        unless(defined $r_engineDlInfo);
    (substr($r_engineDlInfo->{destination},7) =~ /^([^\/\\]+)[\/\\]?$/ && $1 ne '..' && $1 ne '.')
        or fatalError("Invalid engine destination subdirectory \"$r_engineDlInfo->{destination}\" in $type Beyond All Reason launcher JSON configuration file");
    if(defined $engineSubdir) {
      fatalError("Inconsistency between Linux and Windows engine versions in $type Beyond All Reason launcher JSON configuration file (\"$engineSubdir\" , \"$1\")")
          if($engineSubdir ne $1);
    }else{
      $engineSubdir=$1;
    }
    my $os=delete $idFilters{$r_barPackage->{id}};
    $engineDlUrls{$os}=$r_engineDlInfo->{url};
    last unless(%idFilters);
  }
  fatalError('Cannot find appropriate setup data for '.join(' and ',map {ucfirst($_)} sort values %idFilters)." in $type Beyond All Reason launcher JSON configuration file")
      if(%idFilters);
}

sub copyDir {
  my ($sourceDir,$destDir,$maxRecur,$recurLevel)=@_;
  $maxRecur//=10;
  $recurLevel//=0;
  fatalError("Too many nested subdirectories ($recurLevel) encountered when trying to copy directory")
      if($recurLevel > $maxRecur);
  createDir($destDir) unless(-d $destDir);
  opendir(my $sourceDh,$sourceDir)
      or fatalError("Failed to open directory \"$sourceDir\" ($!)");
  my @filesAndDirs = grep {$_ ne '.' && $_ ne '..'} readdir($sourceDh);
  close($sourceDh);
  foreach my $fileOrDir (@filesAndDirs) {
    if(-f "$sourceDir/$fileOrDir") {
      my $sourceFile=catfile($sourceDir,$fileOrDir);
      my $destFile=catfile($destDir,$fileOrDir);
      cp($sourceFile,$destFile)
          or fatalError("Failed to copy file from \"$sourceFile\" to \"$destFile\": $!");
    }elsif(-d "$sourceDir/$fileOrDir") {
      my $sourceSubdir=catdir($sourceDir,$fileOrDir);
      my $destSubdir=catdir($destDir,$fileOrDir);
      copyDir($sourceSubdir,$destSubdir,$maxRecur,$recurLevel+1);
    }
  }
}

sub getBarRapidConf {
  my $dataDir=shift//'';
  state %barRapidConfCache;
  return $barRapidConfCache{$dataDir} if(exists $barRapidConfCache{$dataDir});
  $barRapidConfCache{$dataDir}=undef;
  my $r_launcherConfig=getBarLauncherConfig($dataDir)
      or return;
  my %idFilters = map {$_ => 1} (BAR_LAUNCHER_PACKAGE_ID_WINDOWS,BAR_LAUNCHER_PACKAGE_ID_LINUX);
  foreach my $r_barSetup (@{$r_launcherConfig->{setups}}) {
    next unless(ref $r_barSetup eq 'HASH' && ref $r_barSetup->{package} eq 'HASH');
    my $r_barPackage=$r_barSetup->{package};
    next unless(defined $r_barPackage->{id} && ref $r_barPackage->{id} eq '' && exists $idFilters{$r_barPackage->{id}});
    if(! (defined $barRapidConfCache{$dataDir} && exists $barRapidConfCache{$dataDir}{resolveOrder}) && ref $r_barSetup->{launch} eq 'HASH' && ref $r_barSetup->{launch}{springsettings} eq 'HASH'
       && defined $r_barSetup->{launch}{springsettings}{RapidTagResolutionOrder} && ref $r_barSetup->{launch}{springsettings}{RapidTagResolutionOrder} eq '') {
      $barRapidConfCache{$dataDir}{resolveOrder}=[split(/;/,$r_barSetup->{launch}{springsettings}{RapidTagResolutionOrder})];
    }
    if(! (defined $barRapidConfCache{$dataDir} && exists $barRapidConfCache{$dataDir}{envVars}) && ref $r_barSetup->{env_variables} eq 'HASH'
       && (all {defined $r_barSetup->{env_variables}{$_} && ref $r_barSetup->{env_variables}{$_} eq ''} (keys %{$r_barSetup->{env_variables}}))) {
      $barRapidConfCache{$dataDir}{envVars}=$r_barSetup->{env_variables};
    }
    last if(defined $barRapidConfCache{$dataDir} && exists $barRapidConfCache{$dataDir}{resolveOrder} && exists $barRapidConfCache{$dataDir}{envVars});
  }
  printWarning('Cannot find rapid tag resolution order in '.($dataDir eq '' ? 'online' : 'local').' Beyond All Reason launcher JSON configuration file')
      unless(defined $barRapidConfCache{$dataDir} && exists $barRapidConfCache{$dataDir}{resolveOrder});
  printWarning('Cannot find rapid environment variables declaration in '.($dataDir eq '' ? 'online' : 'local').' Beyond All Reason launcher JSON configuration file')
      unless(defined $barRapidConfCache{$dataDir} && exists $barRapidConfCache{$dataDir}{resolveOrder});
  return $barRapidConfCache{$dataDir};
}

sub getRapidVersions {
  my $versionsGzFile=shift;
  state %rapidVersionsCache;
  return @{$rapidVersionsCache{$versionsGzFile}} if(exists $rapidVersionsCache{$versionsGzFile});
  $rapidVersionsCache{$versionsGzFile}=[];
  return unless(-f $versionsGzFile);
  my $versionsFh=IO::Uncompress::Gunzip->new($versionsGzFile, Transparent => 0)
      or return printWarning("Failed to open compressed rapid versions file \"$versionsGzFile\": ".($GunzipError||'unrecognized compression'));
  my @VERSIONS_DATA_FIELDS=(qw'tag packageHash parentGameName gameName');
  my (%rapidTags,%rapidNames);
  while(my $versionLine=<$versionsFh>) {
    chomp($versionLine);
    my @versionLineArray=split(/,/,$versionLine,4);
    my %versionLineData;
    map {$versionLineData{$VERSIONS_DATA_FIELDS[$_]}=$versionLineArray[$_]//''} (0..$#VERSIONS_DATA_FIELDS);
    $rapidTags{$versionLineData{tag}}=\%versionLineData;
    $rapidNames{$versionLineData{gameName}}=\%versionLineData;
  }
  close($versionsFh);
  $rapidVersionsCache{$versionsGzFile}=[\%rapidTags,\%rapidNames];
  return (\%rapidTags,\%rapidNames);
}

sub resolveRapidVersionInRepository {
  my ($rapidVersion,$rapidRepoDir)=@_;
  my $rapidIdent;
  $rapidIdent=$1 if($rapidVersion =~ /^([\w\-]+):/);
  if(defined $rapidIdent && -f "$rapidRepoDir/$rapidIdent/versions.gz") {
    my ($r_rapidTags,$r_rapidNames)=getRapidVersions(catfile($rapidRepoDir,$rapidIdent,'versions.gz'));
    if(defined $r_rapidTags) {
      return ($r_rapidTags->{$rapidVersion}{packageHash},$r_rapidTags->{$rapidVersion}{parentGameName},$rapidIdent) if(exists $r_rapidTags->{$rapidVersion});
      return ($r_rapidNames->{$rapidVersion}{packageHash},$r_rapidNames->{$rapidVersion}{parentGameName},$rapidIdent) if(exists $r_rapidNames->{$rapidVersion});
    }
  }
  opendir(my $rapidRepoDh,$rapidRepoDir)
      or return printWarning("Failed to open directory \"$rapidRepoDir\" ($!)");
  my @remainingRapidIdents = grep {substr($_,0,1) ne '.' && -f "$rapidRepoDir/$_/versions.gz" && (! defined $rapidIdent || $_ ne $rapidIdent)} readdir($rapidRepoDh);
  closedir($rapidRepoDh);
  foreach my $rapidId (@remainingRapidIdents) {
    my ($r_rapidTags,$r_rapidNames)=getRapidVersions(catfile($rapidRepoDir,$rapidId,'versions.gz'));
    if(defined $r_rapidTags) {
      return ($r_rapidTags->{$rapidVersion}{packageHash},$r_rapidTags->{$rapidVersion}{parentGameName},$rapidId) if(exists $r_rapidTags->{$rapidVersion});
      return ($r_rapidNames->{$rapidVersion}{packageHash},$r_rapidNames->{$rapidVersion}{parentGameName},$rapidId) if(exists $r_rapidNames->{$rapidVersion});
    }
  }
  return;
}

sub resolveRapidVersion {
  my ($rapidVersion,$rapidDir,$r_resolveOrder,$r_alreadyResolvedPackageHashes,$r_requiredVersionsFilePathes)=@_;
  $r_alreadyResolvedPackageHashes//={};
  $r_requiredVersionsFilePathes//={};
  foreach my $rapidRepo (@{$r_resolveOrder}) {
    my $rapidRepoDir=catdir($rapidDir,$rapidRepo);
    next unless(-d $rapidRepoDir);
    my ($rapidPackageHash,$parentGameName,$rapidId)=resolveRapidVersionInRepository($rapidVersion,$rapidRepoDir);
    next unless(defined $rapidPackageHash);
    return if(exists $r_alreadyResolvedPackageHashes->{$rapidPackageHash});
    $r_alreadyResolvedPackageHashes->{$rapidPackageHash}=1;
    $r_requiredVersionsFilePathes->{$rapidRepo}{$rapidId}=1;
    my $r_parentGameHashes;
    if($parentGameName ne '') {
      substr($parentGameName,0,8)='' if(substr($parentGameName,0,8) eq 'rapid://');
      ($r_parentGameHashes)=resolveRapidVersion($parentGameName,$rapidDir,$r_resolveOrder,$r_alreadyResolvedPackageHashes,$r_requiredVersionsFilePathes);
    }
    $r_parentGameHashes//=[];
    return ([@{$r_parentGameHashes},$rapidPackageHash],$r_requiredVersionsFilePathes);
  }
  my %alreadyProcessedRepos = map {$_ => 1} @{$r_resolveOrder};
  opendir(my $rapidDh,$rapidDir)
      or fatalError("Failed to open directory \"$rapidDir\" ($!)");
  my @remainingRepos = grep {substr($_,0,1) ne '.' && -d "$rapidDir/$_" && ! exists $alreadyProcessedRepos{$_}} readdir($rapidDh);
  closedir($rapidDh);
  foreach my $rapidRepo (@remainingRepos) {
    my $rapidRepoDir=catdir($rapidDir,$rapidRepo);
    my ($rapidPackageHash,$parentGameName,$rapidId)=resolveRapidVersionInRepository($rapidVersion,$rapidRepoDir);
    next unless(defined $rapidPackageHash);
    return if(exists $r_alreadyResolvedPackageHashes->{$rapidPackageHash});
    $r_alreadyResolvedPackageHashes->{$rapidPackageHash}=1;
    $r_requiredVersionsFilePathes->{$rapidRepo}{$rapidId}=1;
    my $r_parentGameHashes;
    if($parentGameName ne '') {
      substr($parentGameName,0,8)='' if(substr($parentGameName,0,8) eq 'rapid://');
      ($r_parentGameHashes)=resolveRapidVersion($parentGameName,$rapidDir,$r_resolveOrder,$r_alreadyResolvedPackageHashes,$r_requiredVersionsFilePathes);
    }
    $r_parentGameHashes//=[];
    return ([@{$r_parentGameHashes},$rapidPackageHash],$r_requiredVersionsFilePathes);
  }
  fatalError("Failed to resolve rapid name \"$rapidVersion\" using rapid directory \"$rapidDir\"");
}

sub checkGzStatus {
  fatalError("Failed to read SDP archive \"$_[2]\": $GunzipError") if($_[0] < 0);
  fatalError("Unexpected EOF or I/O error when reading SDP archive \"$_[2]\"") if($_[0] < $_[1]);
}

sub getSdpContent {
  my $sdpFile=shift;
  my $r_gunzipSdp=IO::Uncompress::Gunzip->new($sdpFile, Transparent => 0)
      or fatalError("Failed to open SDP archive \"$sdpFile\": ".($GunzipError||'unrecognized compression'));
  my @sdpContent;
  while(my $gzStatus=$r_gunzipSdp->read(my $readBuf,1)) {
    checkGzStatus($gzStatus,1,$sdpFile);
    my $fileNameLength=unpack('C',$readBuf);
    fatalError("Empty file name in SDP archive \"$sdpFile\"") unless($fileNameLength);
    $gzStatus=$r_gunzipSdp->read($readBuf,$fileNameLength);
    checkGzStatus($gzStatus,$fileNameLength,$sdpFile);
    my %fileInfo=(name => unpack('A*',$readBuf));
    $gzStatus=$r_gunzipSdp->read($readBuf,16);
    checkGzStatus($gzStatus,16,$sdpFile);
    $fileInfo{md5}=unpack('H*',$readBuf);
    $gzStatus=$r_gunzipSdp->read($readBuf,4);
    checkGzStatus($gzStatus,4,$sdpFile);
    $fileInfo{crc32}=unpack('N',$readBuf);
    $gzStatus=$r_gunzipSdp->read($readBuf,4);
    checkGzStatus($gzStatus,4,$sdpFile);
    $fileInfo{size}=unpack('N',$readBuf);
    push(@sdpContent,\%fileInfo);
  }
  return \@sdpContent;
}

sub rapidCopy {
  my ($rapidVersion,$type)=@_;
  my $localDataDir = $opt{"$type-local"} eq '' ? $defaultLocalDataDir : $opt{"$type-local"};
  print "> Importing $type from local rapid repository [$rapidVersion]\n";
    if($opt{verbose}) {
      print "  from: $localDataDir\n";
      print "  to: $dataOutDir\n";
    }
  map {fatalError("Cannot find \"$_\" subdirectory in local $type data directory \"$localDataDir\"") unless(-d "$localDataDir/$_")} (qw'packages pool rapid');
  my ($packagesDir,$poolDir,$rapidDir) = map {catdir($localDataDir,$_)} (qw'packages pool rapid');
  my ($outputPackagesDir,$outputPoolDir,$outputRapidDir) = map {catdir($dataOutDir,$_)} (qw'packages pool rapid');
  createDir($outputPackagesDir);
  my $r_barRapidConf=getBarRapidConf($localDataDir);
  my @rapidResolveOrder;
  @rapidResolveOrder=@{$r_barRapidConf->{resolveOrder}} if(defined $r_barRapidConf && exists $r_barRapidConf->{resolveOrder});
  my ($r_rapidPackagesHashes,$r_requiredVersionsFilePathes)=resolveRapidVersion($rapidVersion,$rapidDir,\@rapidResolveOrder);
  foreach my $rapidPackageHash (@{$r_rapidPackagesHashes}) {
    my $sdpFile=catfile($packagesDir,$rapidPackageHash.'.sdp');
    fatalError("Missing local SDP package file \"$sdpFile\"") unless(-f $sdpFile);
    my $r_sdpContent=getSdpContent($sdpFile);
    foreach my $r_fileInfo (@{$r_sdpContent}) {
      my ($poolSubdir,$poolFileName)=(substr($r_fileInfo->{md5},0,2),substr($r_fileInfo->{md5},2).'.gz');
      my $outputPoolSubdir=catdir($outputPoolDir,$poolSubdir);
      my $outputPoolFile=catfile($outputPoolSubdir,$poolFileName);
      next if(-f $outputPoolFile);
      my $localPoolFile=catfile($poolDir,$poolSubdir,$poolFileName);
      fatalError("Missing local pool data file \"$localPoolFile\" referenced by local SDP file \"$sdpFile\"") unless(-f $localPoolFile);
      createDir($outputPoolSubdir,'output pool subdirectory') unless(-d $outputPoolSubdir);
      cp($localPoolFile,$outputPoolFile)
          or fatalError("Failed to copy rapid pool data file from \"$localPoolFile\" to \"$outputPoolFile\": $!");
    }
    my $outputSdpFile=catfile($outputPackagesDir,$rapidPackageHash.'.sdp');
    next if(-f $outputSdpFile);
    cp($sdpFile,$outputSdpFile)
        or fatalError("Failed to copy rapid package file from \"$sdpFile\" to \"$outputSdpFile\": $!");
  }
  foreach my $rapidRepo (keys %{$r_requiredVersionsFilePathes}) {
    foreach my $rapidId (keys %{$r_requiredVersionsFilePathes->{$rapidRepo}}) {
      my $versionsGzFile=catfile($rapidDir,$rapidRepo,$rapidId,'versions.gz');
      my $outputRapidIdDir=catdir($outputRapidDir,$rapidRepo,$rapidId);
      createDir($outputRapidIdDir,'output rapid subdirectory') unless(-d $outputRapidIdDir);
      my $outputVersionsGzFile=catfile($outputRapidIdDir,'versions.gz');
      cp($versionsGzFile,$outputVersionsGzFile)
          or fatalError("Failed to copy rapid versions file from \"$versionsGzFile\" to \"$outputVersionsGzFile\": $!");
      cp($versionsGzFile.'.etag',$outputVersionsGzFile.'.etag') if(-f $versionsGzFile.'.etag');
    }
    my $reposGzFile=catfile($rapidDir,$rapidRepo,'repos.gz');
    next unless(-f $reposGzFile);
    my $outputReposGzFile=catfile($outputRapidDir,$rapidRepo,'repos.gz');
    cp($reposGzFile,$outputReposGzFile)
        or printWarning("Failed to copy rapid repository index file from \"$reposGzFile\" to \"$outputReposGzFile\": $!");
  }
}

sub getPrdBin {
  state $prdBin;
  return $prdBin if(defined $prdBin);
  my $tmpDir=getTmpDir();
  if($opt{verbose}) {
    print "> Downloading pr-downloader\n";
    print '  from: '.BAR_PRD_BASE_URL."\n";
    print "  to: $tmpDir\n";
  }
  my $prdBinName = 'pr-downloader'.(MSWIN32 ? '.exe' : '');
  my @prdFiles=($prdBinName);
  push(@prdFiles,(qw'cacert.pem libcurl.dll zlib1.dll')) if(MSWIN32);
  map {downloadFile(BAR_PRD_BASE_URL.$_,catfile($tmpDir,$_),$_)} @prdFiles;
  $prdBin=catfile($tmpDir,$prdBinName);
  chmod(0755,$prdBin) unless(MSWIN32);
  return $prdBin;
}

sub portableSystem {
  my ($program,@params)=@_;
  my @args=($program,@params);
  @args=map {escapeWin32Parameter($_)} @args if(MSWIN32);
  system {$program} @args;
  if($? == -1) {
    return (undef,$!);
  }elsif($? & 127) {
    return (undef,sprintf("Process died with signal %d, %s coredump", $? & 127 , ($? & 128) ? 'with' : 'without'));
  }else{
    return ($? >> 8);
  }
}

sub rapidDownload {
  my ($rapidVersion,$type)=@_;
  my $prdBin=getPrdBin();
  print "> Downloading $type using pr-downloader [$rapidVersion]\n";
  print "  to: $dataOutDir\n" if($opt{verbose});
  open(my $previousStdout,'>&',\*STDOUT);
  open(STDOUT,'>',devnull());
  my ($ec,$prdErrMsg)=portableSystem($prdBin,'--disable-logging','--filesystem-writepath',$dataOutDir,'--download-game',$rapidVersion);
  open(STDOUT,'>&',$previousStdout);
  fatalError("Failed to run pr-downloader ($prdErrMsg)")
      unless(defined $ec);
  fatalError("pr-downloader exited with code $ec when trying to download $type \"$rapidVersion\"")
      if($ec);
}

sub getCurrentGmTime {
  my @gmTime = gmtime();
  $gmTime[4]++;
  @gmTime = map(sprintf('%02d',$_),@gmTime);
  return join('/',$gmTime[5]+1900,@gmTime[4,3]).' '.join(':',@gmTime[2,1,0]).' GMT';
}

###################
# MAIN PROCESSING #
###################

GetOptions(\%opt,qw'
           help|h
           version|v
           verbose|V
           tasks|t=s
           disable|d=s
           engine|e=s
           engine-local|E:s
           game|g=s
           game-local|G:s
           chobby|c=s
           chobby-local|C:s
           maps|m:s
           maps-local|M:s
           local-datadir|L:s
           linux|l
           windows|w
           output|o=s
           force|f
           ')
    or badUsage();

processCmdLineOptions();

print "\n[getOfflineBarPackages v$VERSION]\n";
print "Output: $outDir\n";

print "---- start of processing ----\n";

print "[1/6] INSTALLER\n";
if($tasks{installer}) {
  my $barDlPageContent=httpGet(BAR_DOWNLOAD_URL,'Beyond All Reason download page');
  if(! $opt{linux}) {
    fatalError('Failed to find Windows installer link in Beyond All Reason download page')
        unless($barDlPageContent =~ /(\Q$BAR_DOWNLOAD_BASE_URL\E[^\/]+\/(Beyond-All-Reason-([\d\.]+)\.exe))/);
    my ($installerUrl,$installerFile,$installerVersion)=($1,catfile($outDir,$2),$3);
    print "> Downloading Windows installer [$installerVersion]\n";
    if($opt{verbose}) {
      print "  from: $installerUrl\n";
      print "  to: $installerFile\n";
    }
    downloadFile($installerUrl,$installerFile,'Beyond All Reason Windows installer');
  }
  if(! $opt{windows}) {
    fatalError('Failed to find Linux AppImage link in Beyond All Reason download page')
        unless($barDlPageContent =~ /(\Q$BAR_DOWNLOAD_BASE_URL\E[^\/]+\/(Beyond-All-Reason-([\d\.]+)\.AppImage))/);
    my ($appImageUrl,$appImageFile,$installerVersion)=($1,catfile($outDir,$2),$3);
    print "> Downloading Linux AppImage [$installerVersion]\n";
    if($opt{verbose}) {
      print "  from: $appImageUrl\n";
      print "  to: $appImageFile\n";
    }
    downloadFile($appImageUrl,$appImageFile,'Beyond All Reason Linux AppImage');
  }
}else{
  print "> Disabled\n";
}

print "[2/6] ENGINE\n";
if($tasks{engine}) {
  if(defined $opt{'engine-local'}) {
    my $localDataDir = $opt{'engine-local'} eq '' ? $defaultLocalDataDir : $opt{'engine-local'};
    fatalError("Cannot find \"engine\" subdirectory in local engine data directory \"$localDataDir\"")
        unless(-d "$localDataDir/engine");
    my $localEngineDir=catdir($localDataDir,'engine');
    opendir(my $localEngineDh,$localEngineDir)
        or fatalError("Failed to open directory \"$localEngineDir\" ($!)");
    my @localEngineSubdirs = grep {/\d+(?:\.\d+){1,3}(?:-\d+-g[0-9a-f]+)?(?: bar)?$/ && -d "$localEngineDir/$_"} readdir($localEngineDh);
    closedir($localEngineDh);
    fatalError("No engine found in local engine directory \"$localEngineDir\"")
        unless(@localEngineSubdirs);
    if($opt{engine}) {
      $engineSubdir = first {$opt{engine} eq $_ || $opt{engine}.' bar' eq $_} @localEngineSubdirs;
      $engineSubdir //= first {index($_,$opt{engine}) > -1} @localEngineSubdirs;
      fatalError("Cannot find matching local engine for version \"$opt{engine}\"")
          unless(defined $engineSubdir);
    }else{
      retrieveEngineInfoFromBarLauncherConfig($localDataDir);
      fatalError("Engine subdirectory \"$engineSubdir\" specified in local Beyond All Reason launcher configuration was not found in local engine data directory \"$localEngineDir\"")
          unless(any {$engineSubdir eq $_} @localEngineSubdirs);
    }
    my $engineVersion = $engineSubdir =~ /(\d+(?:\.\d+){1,3}(?:-\d+-g[0-9a-f]+)?)(?: bar)?$/ ? $1 : '?';
    my $sourceEngineDir=catdir($localEngineDir,$engineSubdir);
    foreach my $os (qw'linux windows') {
      next if(($os eq 'windows' && $opt{linux}) || ($os eq 'linux' && $opt{windows}));
      my $expectedEngineBin='spring'.($os eq 'windows' ? '.exe' : '');
      my $printedOs=ucfirst($os);
      fatalError("Cannot import $printedOs engine \"$engineSubdir\" from local engine data directory \"$localEngineDir\": expected binary \"$expectedEngineBin\" not found (use ".($os eq 'windows' ? '-l' : '-w').' parameter to skip import for this OS)')
          unless(-f "$sourceEngineDir/$expectedEngineBin");
      my $destEngineDir=catdir($outDir,'data-'.$os,'engine',$engineSubdir);
      print "> Importing engine for $printedOs from local engine directory [$engineVersion]\n";
      if($opt{verbose}) {
        print "  from: $sourceEngineDir\n";
        print "  to: $destEngineDir\n";
      }
      copyDir($sourceEngineDir,$destEngineDir);
    }
  }else{
    my $engineVersion;
    if($opt{engine}) {
      my $repositoryTagsJson=httpGet('https://github.com/'.BAR_GITHUB_REPOSITORY.'/refs?type=tag',
                                     'available engine tags on Beyond All Reason GitHub repository',
                                     0,
                                     {headers => {Accept => 'application/json'}});
      my $r_tagsData=decodeJson(\$repositoryTagsJson,'JSON response from GitHub when listing repository tags','refs');
      my $engineTag = first {$opt{engine} eq $_} @{$r_tagsData->{refs}};
      $engineTag //= first {index($_,$opt{engine}) > -1} @{$r_tagsData->{refs}};
      fatalError("Cannot find matching engine release for version \"$opt{engine}\"")
          unless(defined $engineTag);
      my $expandedAssetContent=httpGet('https://github.com/'.BAR_GITHUB_REPOSITORY.'/releases/expanded_assets/'.$engineTag,
                                       "GitHub release info for release \"$engineTag\" on Beyond All Reason repository");
      my %assetFilters = (
        'windows-64' => 'windows',
        'linux-64' => 'linux',
          );
      foreach my $assetFilter (sort keys %assetFilters) {
        my $os=$assetFilters{$assetFilter};
        fatalError('Cannot find appropriate asset for '.ucfirst($os)." in GitHub release info for release \"$engineTag\" of Beyond All Reason repository")
            unless($expandedAssetContent =~ /href="([^"]+\/[^"\/]*?(\d+(?:\.\d+){1,3}(?:-\d+-g[0-9a-f]+)?)\/[^"\/]+\Q_$assetFilter-minimal-portable.7z\E)"/);
        my ($engineDlUrl,$engineVersionOs)=($1,$2);
        if(defined $engineVersion) {
          fatalError("Inconsistency between Linux and Windows engine versions in GitHub release info for release \"$engineTag\" of Beyond All Reason repository (\"$engineVersion\" , \"$engineVersionOs\")")
              if($engineVersion ne $engineVersionOs);
        }else{
          $engineVersion=$engineVersionOs;
          $engineSubdir=$engineVersion.' bar';
        }
        $engineDlUrl='https://github.com'.$engineDlUrl if(substr($engineDlUrl,0,1) eq '/');
        $engineDlUrls{$os}=$engineDlUrl;
      }
    }else{
      retrieveEngineInfoFromBarLauncherConfig();
      $engineVersion = $engineSubdir =~ /(\d+(?:\.\d+){1,3}(?:-\d+-g[0-9a-f]+)?)(?: bar)?$/ ? $1 : '?';
    }
    foreach my $os (sort keys %engineDlUrls) {
      next if(($os eq 'windows' && $opt{linux}) || ($os eq 'linux' && $opt{windows}));
      $engineDlUrls{$os} =~ /\/([^\/]+)$/;
      my $tmpEngineArchive=catfile(getTmpDir(),$1);
      print '> Downloading engine for '.ucfirst($os)." [$engineVersion]\n";
      if($opt{verbose}) {
        print "  from: $engineDlUrls{$os}\n";
        print "  to: $tmpEngineArchive\n";
      }
      downloadFile($engineDlUrls{$os},$tmpEngineArchive,'engine archive');
      my $engineDestDir=catdir($outDir,'data-'.$os,'engine',$engineSubdir);
      createDir($engineDestDir,'output directory for engine');
      uncompress7zipFile($tmpEngineArchive,$engineDestDir,'engine for '.ucfirst($os));
    }
  }
}else{
  if($opt{engine}) {
    $engineSubdir=$opt{engine};
    $engineSubdir.=' bar' unless(substr($engineSubdir,-4) eq ' bar');
  }
  print "> Disabled\n";
}

print "[3/6] GAME\n";
if($tasks{game}) {
  if(defined $opt{'game-local'}) {
    rapidCopy($gameRapidVersion,'game');
  }else{
    my $r_barRapidConf=getBarRapidConf();
    if(defined $r_barRapidConf && exists $r_barRapidConf->{envVars}) {
      map {$ENV{$_}=$r_barRapidConf->{envVars}{$_}} (keys %{$r_barRapidConf->{envVars}});
    }
    rapidDownload($gameRapidVersion,'game');
  }
}else{
  print "> Disabled\n";
}

print "[4/6] CHOBBY\n";
if($tasks{chobby}) {
  if(defined $opt{'chobby-local'}) {
    rapidCopy($chobbyRapidVersion,'chobby');
  }else{
    my $r_barRapidConf=getBarRapidConf();
    if(defined $r_barRapidConf && exists $r_barRapidConf->{envVars}) {
      map {$ENV{$_}=$r_barRapidConf->{envVars}{$_}} (keys %{$r_barRapidConf->{envVars}});
    }
    rapidDownload($chobbyRapidVersion,'chobby');
  }
}else{
  print "> Disabled\n";
}

print "[5/6] MAPS\n";
if(defined $opt{maps}) {
  my $localDataDir;
  if($opt{maps} eq '') {
    $localDataDir=$defaultLocalDataDir if(defined $defaultLocalDataDir && -d "$defaultLocalDataDir/maps");
  }else{
    fatalError("Cannot find \"maps\" subdirectory in specified local data directory for map archives \"$opt{maps}\"")
        unless(-d "$opt{maps}/maps");
    $localDataDir=$opt{maps};
  }
  my $localMapsDir;
  $localMapsDir=catdir($localDataDir,'maps') if(defined $localDataDir);
  my $mapInventoryJson=httpGet(BAR_MAPS_INVENTORY_URL,'online Beyond All Reason maps inventory file');
  my $r_barMapList = eval { decode_json($mapInventoryJson) };
  if(! defined $r_barMapList) {
    my $jsonDecodeError='unknown error';
    if($@) {
      chomp($@);
      $jsonDecodeError=$@;
    }
    fatalError("Failed to parse online Beyond All Reason maps inventory file: $jsonDecodeError");
  }
  return fatalError("Unexpected data type in online Beyond All Reason maps inventory file (not an array)")
      unless(ref $r_barMapList eq 'ARRAY');
  my (%barMapUrls,@InvalidMapUrls);
  foreach my $r_mapData (@{$r_barMapList}) {
    next unless(ref $r_mapData eq 'HASH' && defined $r_mapData->{downloadURL} && ref $r_mapData->{downloadURL} eq '');
    if($r_mapData->{downloadURL} =~ /\/([^\/]+\.sd[7z])$/i) {
      $barMapUrls{$r_mapData->{downloadURL}}=$1;
    }else{
      push(@InvalidMapUrls,$r_mapData->{downloadURL});
    }
  }
  printWarning('Found '.(scalar @InvalidMapUrls).' unrecognized map download URL (first one is "'.$InvalidMapUrls[0].'"')
      if(@InvalidMapUrls);
  fatalError('No URL found in online Beyond All Reason maps inventory file')
      unless(keys %barMapUrls);
  my $outputMapsDir=catdir($dataOutDir,'maps');
  if(-e $outputMapsDir) {
    fatalError("Output path for maps \"$outputMapsDir\" already exists and is NOT a directory") unless(-d $outputMapsDir);
  }else{
    createDir($outputMapsDir,'output directory for maps');
  }
  my ($nbSkippedMaps,@mapUrlsToProcess);
  map {-e "$outputMapsDir/$barMapUrls{$_}" ? $nbSkippedMaps++ : push(@mapUrlsToProcess,$_)} (keys %barMapUrls);
  print "> $nbSkippedMaps Beyond All Reason map archive".($nbSkippedMaps>1?'s':'')." already in output directory\n"
      if($nbSkippedMaps);
  if(@mapUrlsToProcess) {
    my $nbMapsToProcess=@mapUrlsToProcess;
    my %localMapUrls;
    if(defined $localMapsDir) {
      map {$localMapUrls{$_}=1 if(-f "$localMapsDir/$barMapUrls{$_}")} @mapUrlsToProcess;
    }
    my $nbLocalMaps=keys %localMapUrls;
    my $nbDownloads=$nbMapsToProcess-$nbLocalMaps;
    if($nbLocalMaps) {
      if($nbDownloads) {
        print "> Importing $nbMapsToProcess Beyond All Reason map archive".($nbMapsToProcess>1?'s':'')."\n";
        print "    (copy from local maps data directory: $nbLocalMaps, download: $nbDownloads)\n";
      }else{
        print "> Importing $nbMapsToProcess Beyond All Reason map archive".($nbMapsToProcess>1?'s':'')." from local maps data directory\n";
      }
    }else{
      print "> Downloading $nbMapsToProcess Beyond All Reason map archive".($nbMapsToProcess>1?'s':'')."\n";
    }
    $|=1;
    print '  [';
    foreach my $mapUrl (sort @mapUrlsToProcess) {
      my $mapArchive=$barMapUrls{$mapUrl};
      my $outputMapFile=catfile($outputMapsDir,$mapArchive);
      if($localMapUrls{$mapUrl}) {
        my $localMapFile=catfile($localMapsDir,$mapArchive);
        cp($localMapFile,$outputMapFile)
            or fatalError("Failed to copy map archive file from \"$localMapFile\" to \"$outputMapFile\": $!");
        print '*';
      }else{
        downloadFile($mapUrl,$outputMapFile,'map archive');
        print '#';
      }
    }
    $|=0;
    print "]\n";
  }
}elsif(defined $opt{'maps-local'}) {
  my $localDataDir = $opt{'maps-local'} eq '' ? $defaultLocalDataDir : $opt{'maps-local'};
  fatalError("Cannot find \"maps\" subdirectory in local maps data directory \"$localDataDir\"")
      unless(-d "$localDataDir/maps");
  my $localMapsDir=catdir($localDataDir,'maps');
  opendir(my $localMapsDh,$localMapsDir)
      or fatalError("Failed to open directory \"$localMapsDir\" ($!)");
  my @localMapArchives = grep {/\.sd[7z]$/ && -f "$localMapsDir/$_"} readdir($localMapsDh);
  closedir($localMapsDh);
  fatalError("No map archive found in local maps directory \"$localMapsDir\"")
      unless(@localMapArchives);
  my $outputMapsDir=catdir($dataOutDir,'maps');
  if(-e $outputMapsDir) {
    fatalError("Output path for maps \"$outputMapsDir\" already exists and is NOT a directory") unless(-d $outputMapsDir);
  }else{
    createDir($outputMapsDir,'output directory for maps');
  }
  my ($nbSkippedMaps,@mapsToProcess);
  map {-e "$outputMapsDir/$_" ? $nbSkippedMaps++ : push(@mapsToProcess,$_)} @localMapArchives;
  print "> $nbSkippedMaps local map archive".($nbSkippedMaps>1?'s':'')." already in output directory\n"
      if($nbSkippedMaps);
  if(@mapsToProcess) {
    my $nbMapsToProcess=@mapsToProcess;
    print "> Importing $nbMapsToProcess map archive".($nbMapsToProcess>1?'s':'')." from local maps data directory\n";
    $|=1;
    print '  [';
    foreach my $mapArchive (sort @mapsToProcess) {
      my $localMapFile=catfile($localMapsDir,$mapArchive);
      my $outputMapFile=catfile($outputMapsDir,$mapArchive);
      cp($localMapFile,$outputMapFile)
          or fatalError("Failed to copy map archive file from \"$localMapFile\" to \"$outputMapFile\": $!");
      print '*';
    }
    $|=0;
    print "]\n";
  }
}else{
  print "> Disabled\n";
}

print "[6/6] LAUNCHER\n";
my $engineInfoString = defined $engineSubdir ? ("\"$engineSubdir\"".(defined $engineDlUrls{linux} ? '' : ' (no download link!)')) : 'none';
if($tasks{launcher}) {
  my $sourceDirForLauncherConfigFile = defined $opt{'local-datadir'} && -f "$opt{'local-datadir'}/config.json" ? $opt{'local-datadir'} : undef;
  print "> Generating Beyond All Reason launcher configuration files\n";
  print '  . source: '.(defined $sourceDirForLauncherConfigFile ? 'local' : 'online')."\n";
  print "  . engine: $engineInfoString\n";
  print "  . game: \"$gameRapidVersion\"\n";
  print "  . Chobby: \"$chobbyRapidVersion\"\n";
  my $r_launcherCfg=getBarLauncherConfig($sourceDirForLauncherConfigFile)
      or fatalError('Cannot generate custom Beyond All Reason launcher configuration (no source configuration found)');
  my ($r_linuxSetup,$r_windowsSetup);
  foreach my $r_barSetup (@{$r_launcherCfg->{setups}}) {
    next unless(ref $r_barSetup eq 'HASH' && ref $r_barSetup->{package} eq 'HASH');
    my $r_barPackage=$r_barSetup->{package};
    next unless(defined $r_barPackage->{id} && ref $r_barPackage->{id} eq '');
    if($r_barPackage->{id} eq BAR_LAUNCHER_PACKAGE_ID_LINUX) {
      fatalError('Duplicate Linux setup found in Beyond All Reason launcher configuration file')
          if(defined $r_linuxSetup);
      $r_linuxSetup=dclone($r_barSetup);
    }elsif($r_barPackage->{id} eq BAR_LAUNCHER_PACKAGE_ID_WINDOWS) {
      fatalError('Duplicate Windows setup found in Beyond All Reason launcher configuration file')
          if(defined $r_windowsSetup);
      $r_windowsSetup=dclone($r_barSetup);
    }
    last if(defined $r_linuxSetup && defined $r_windowsSetup);
  }
  fatalError('Unable to find Linux setup in Beyond All Reason launcher configuration file')
      unless(defined $r_linuxSetup);
  fatalError('Unable to find Windows setup in Beyond All Reason launcher configuration file')
      unless(defined $r_windowsSetup);
  foreach my $r_barSetup ($r_linuxSetup,$r_windowsSetup) {
    my $r_barPackage=$r_barSetup->{package};
    my $os = $r_barPackage->{id} eq BAR_LAUNCHER_PACKAGE_ID_LINUX ? 'linux' : 'windows';
    $r_barPackage->{display}='Custom';
    $r_barPackage->{id} = 'custom-'.($os eq 'windows' ? 'win' : $os);
    delete $r_barSetup->{config_url};
    $r_barSetup->{downloads}={
      games => [$gameRapidVersion,$chobbyRapidVersion],
      exists $engineDlUrls{$os} ? (
        resources => [ {
          url => $engineDlUrls{$os},
          destination => 'engine/'.$engineSubdir,
          extract => $JSON::PP::true,
                        } ],
          ) : (),
    };
    delete $r_barSetup->{logs_s3_bucket};
    $r_barSetup->{launch}{start_args}=['--menu',(substr($chobbyRapidVersion,0,12) eq 'byar-chobby:' ? 'rapid://' : '').$chobbyRapidVersion];
    $r_barSetup->{launch}{engine}=$engineSubdir;
  }
  my $r_launcherCfgWithCustom=dclone($r_launcherCfg);
  push(@{$r_launcherCfgWithCustom->{setups}},$r_linuxSetup,$r_windowsSetup);
  my $r_launcherCfgCustomOnly=dclone($r_launcherCfg);
  $r_launcherCfgCustomOnly->{title}.='\\n(custom)';
  $r_launcherCfgCustomOnly->{setups}=[$r_linuxSetup,$r_windowsSetup];
  my $jsonEncoder=JSON::PP->new()->sort_by(
    sub {($BAR_LAUNCHER_CFG_FIELD_IDX{$JSON::PP::a} // 999) <=> ($BAR_LAUNCHER_CFG_FIELD_IDX{$JSON::PP::b} // 999)
             or $JSON::PP::a cmp $JSON::PP::b})->indent()->indent_length(4)->space_after();
  my $jsonLauncherCfgWithCustom = eval { $jsonEncoder->encode($r_launcherCfgWithCustom) };
  if(! defined $jsonLauncherCfgWithCustom) {
    my $jsonEncodeError='unknown error';
    if($@) {
      chomp($@);
      $jsonEncodeError=$@;
    }
    fatalError("Failed to generate Beyond All Reason launcher configuration (with custom setups) in JSON format: $jsonEncodeError");
  }
  my $jsonLauncherCfgCustomOnly = eval { $jsonEncoder->encode($r_launcherCfgCustomOnly) };
  if(! defined $jsonLauncherCfgCustomOnly) {
    my $jsonEncodeError='unknown error';
    if($@) {
      chomp($@);
      $jsonEncodeError=$@;
    }
    fatalError("Failed to generate Beyond All Reason launcher configuration (with custom setups only) in JSON format: $jsonEncodeError");
  }
  foreach my $launcherCfgFile (catfile($dataOutDir,'config.json'),catfile($dataOutDir,'config-custom.json')) {
    open(my $launcherCfgFh,'>',$launcherCfgFile)
        or fatalError("Failed to open file \"$launcherCfgFile\" for writing ($!)");
    binmode($launcherCfgFh);
    print $launcherCfgFh $jsonLauncherCfgWithCustom;
    close($launcherCfgFh);
  }
  my $launcherCfgFile=catfile($dataOutDir,'config-custom-only.json');
  open(my $launcherCfgFh,'>',$launcherCfgFile)
      or fatalError("Failed to open file \"$launcherCfgFile\" for writing ($!)");
  binmode($launcherCfgFh);
  print $launcherCfgFh $jsonLauncherCfgCustomOnly;
  close($launcherCfgFh);
  my $devmodeTxtFile=catfile($dataOutDir,'devmode.txt');
  open(my $devmodeTxtFh,'>',$devmodeTxtFile)
      or fatalError("Failed to create file \"$devmodeTxtFile\" ($!)");
  close($devmodeTxtFh);
  foreach my $os (qw'windows linux') {
    my $osLauncherCfgFile=catfile($outDir,'data-'.$os,'launcher_cfg.json');
    open(my $osLauncherCfgFh,'>',$osLauncherCfgFile)
        or fatalError("Failed to open file \"$osLauncherCfgFile\" for writing ($!)");
    binmode($osLauncherCfgFh);
    my $shortOs=$os;
    $shortOs='win' if($shortOs eq 'windows');
    print $osLauncherCfgFh "{\n  \"config\": \"custom-$shortOs\",\n  \"checkForUpdates\": false\n}\n";
    close($osLauncherCfgFh);
  }
}else{
  print "> Disabled\n";
}

my $currentGmTime=getCurrentGmTime();
my $readmeFile=catfile($outDir,'README.txt');
open(my $readmeFh,'>',$readmeFile)
    or fatalError("Failed to open file \"$readmeFile\" for writing ($!)");
binmode($readmeFh);

print $readmeFh <<EOF;
This directory contains the files required to install/update/configure Beyond All Reason for offline play with a LAN server.

Install/update procedure for Windows systems:
=============================================
1) If Beyond All Reason is NOT installed on the system yet:
     . run the installer (Beyond-All-Reason-X.XXXX.X.exe)
     . note the install directory as it will be used in step 2
     . at the end of the installation, uncheck "Run Beyond-All-Reason" before clicking on "Finish"
   If Beyond All Reason is already installed on the system:
     . start the Beyond All Reason launcher
     . click on the "Open Install Directory" button (this will automatically open the "data" subdirectory of your Beyond All Reason install directory, which will be used in step 2)
     . close the Beyond All Reason launcher
2) Copy the content of the "data" and "data-windows" directories into the "data" subdirectory of your Beyond All Reason install directory, overwriting files if needed

Install/update procedure for Linux systems:
===========================================
1) If Beyond All Reason is NOT installed on the system yet:
     . Copy the Beyond All Reason AppImage file (Beyond-All-Reason-X.XXXX.X.AppImage) locally and set execute permission on it
     . Identify the directory that will be used to store game data:
         If the XDG_STATE_HOME environment variable is defined, then the Beyond All Reason data directory is: "\$XDG_STATE_HOME/Beyond All Reason"
         Else the Beyond All Reason data directory is "\$HOME/.local/state/Beyond All Reason"
     . Create the Beyond All Reason data directory
   If Beyond All Reason is already installed on the system:
     . start the Beyond All Reason launcher (Beyond All Reason AppImage)
     . click on the "Open Install Directory" button (this will automatically open the Beyond All Reason data directory)
     . close the Beyond All Reason launcher
2) Copy the content of the "data" and "data-linux" directories into the Beyond All Reason data directory, overwriting files if needed

Configuration of Beyond All Reason client (Chobby):
===================================================
1) Start the Beyond All Reason launcher, ensure the "Update" checkbox is unchecked and the "Custom" config is selected in the top right dropdown menu before clicking on "Start"
2) If the "Register" window opens automatically: click on "Cancel"
3) In the right menu, click on the "Settings" tab then on the "Developer" subtab
4) In the "Server Address" field, replace the default value with the IP address of the LAN server
5) Click on the "Login" button in the top right corner
6) In the window that just opened, ensure the "Login" tab is selected
7) Type the desired user name for local play in the "Username" field, then click on the "Login" button (you can leave the "Password" field empty as it is ignored by the LAN server)
8) In the left menu, click on the "Multiplayer & Coop" button then on the "Battle list" button


---------------------------------------------------
getOfflineBarPackages v$VERSION
  date: $currentGmTime
  engine: $engineInfoString
  game: "$gameRapidVersion"
  Chobby: "$chobbyRapidVersion"
---------------------------------------------------
EOF

close($readmeFh);

print "---- end of processing ----\n";

print "\n" unless(MSWIN32);
