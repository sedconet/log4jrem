:
eval 'exec $NCHOME/precision/bin/ncp_perl -S $0 ${1+"$@"}'
  if $bogus_variable_to_keep_perl_happy;
################################################
#
#
# Licensed Materials - Property of IBM
#
# "Restricted Materials of IBM"
#
# 5724-S45
#
# (C) Copyright IBM Corp. 1997, 2013
#
# IBM Tivoli Network Manager IP Edition
#
################################################

#############################################################################
#
# ncp_testfix.pl
#
# Description:
#
# This perl script will install and remove fixes. Run with the -help
# option for further details.
#
# Assumptions:
#   (1) The fix has been supplied as a bundle relative to
#       $NCHOME or $TIPHOME depending on whether it is a CORE or a GUI fix
#
# Usage (PERL below refers to $NCHOME/precision/perl/bin/ncp_perl):
# You can source $NCHOME/env.sh script to get PERL added to your PATH
#   To install a test fix:
#       PERL ncp_testfix.pl -install PATH_TO_TESTFIX_TARBALL
#   To remove an installed test fix, and remove the original files:
#       PERL ncp_testfix.pl -remove NAME_OF_TEST_FIX
#   To list the testfixes, run
#       PERL ncp_testfix.pl -list
#
# Results:
#   Upon installation, the fix package has been installed. Any files
#   that existed already have been copied to a backup directory, from which
#   they can be removed later on by running the script with the -remove
#   option.
#   When restoring the original version after trying out a fix, the
#   contents of the backup dir will be returned to their original locations.
#   This assumes that the initial testfix was unpacked using this script.
#
# 2/10/13   :   added versioning and upgrading of perl file in $NCHOME service
#           :   added zLinux OS detection fix
#           :   changed references to testfix/APARS to just fix
#           :   removed some exit()s to allow loading and testing of the script from another
#           :   alm00299729 :   Verify fix matches supplied -core/-gui/-tcr etc.
#           ;               :   Verify fix archive passed on command line is not parent archive
# 16/10/13  :   added version printing and some comparison
# 24/10/13  :   added windows check before printing about script run as root
#           ;   made core testfix check look for precision anywhere instead of first line
#############################################################################

use strict;
use warnings;

use Archive::Tar;
use Archive::Tar::File;
use Archive::Zip qw( :ERROR_CODES );
use Cwd;
use Data::Dumper;
use File::Basename;
use File::Copy;
use File::Path;
use File::Spec;
use Getopt::Long qw( :config pass_through );

#For zLinux OS check
use Config;

use RIV;

my $startDir = Cwd::cwd();

# should be obvious
# $nchomeDir - $NCHOME
# $serviceDir - $NCHOME/service
# $precisionDir - $NCHOME/precision
# $rootDir = $NCHOME for core APARs and $TIPHOME for GUI APARs
my (
    $nchomeDir, $serviceDir, $rootDir, $precisionDir, $backupDir,
    $logfile,   $aparList,   $fixDir,  $filelist
);
my ( $verbose, $zipFile, $readdir, $coreApar, $guiApar, $tcrApar ) = (0) x 6;
my (
    $aparNum, $platform, $buildLevel, $version,
    $fixName, $tarball,  $userName,   $currentOS
);

my $coreList = "$startDir/corefilelist";
my $guiList  = "$startDir/guifilelist";
my $tcrList  = "$startDir/tcrfilelist";

my @scriptArgs;

#add versioning
our $SCRIPT_VERSION = "0.001_001";    # or "0.001_001" for a dev release
$SCRIPT_VERSION = eval $SCRIPT_VERSION;

processCmdLine();

################################################
# The main functionality
################################################

sub checkPerl {

    # if RIV.pm supports ReadDir then we don't care if the script is run using
    # ncp_perl or perl
    # however, if RIV.pm doesn't support ReadDir (in 3.8 for example), then the
    # script should be run using perl
    #
    my $binary = basename $^X;
    if ( $binary =~ m/^perl.*$/ ) {

# if perl is being used no issues, we will use Perl's opendir to read a directory
# and move on
        return;
    }

    # we are using ncp_perl, check if ReadDir is supported
    if ( RIV->can('ReadDir') ) {
        $readdir = 1;
        return;
    }

    # if we are here, then user is running using ncp_perl
    # AND we are running on 3.8 install
    #
    my $script  = $0;
    my $perlBin = "$nchomeDir/precision/perl/bin/perl";
    if ( !-e $perlBin ) {

        # windows may be?
        #
        $perlBin = "$nchomeDir/precision/perl/bin/perl.exe";
        if ( !-e $perlBin ) {
            warning("ITNM perl $perlBin does not exist ... exiting");
            exit;
        }
    }

    info("Running the script using $perlBin due to compatibility issues");

    # exec the script by running with $NCHOME/precision/perl/bin/perl
    system("$perlBin $script @scriptArgs");
    exit;
}

sub createServiceDir {

    # if this is the first time then the service dir may not exist, create it
    # first
    if ( !-d $serviceDir ) {
        mkdir $serviceDir
          or die "Unable to create backup directory $serviceDir: $!\n";
    }

    # also copy the current script to the service dir
    my $src    = $0;
    my $script = basename $src;
    my $dest   = "$serviceDir/$script";

    if ( !-f $dest ) {
        copy $src, $dest or warning("Unable to copy $src to $dest: $!");
    }
    elsif ( checkIfNewerVersion($dest) ) {

    #This version is newer than the one in the service directory so copy it over
    #unless they are the same file
        if ( $src ne $dest ) {
            copy $src, $dest or warning("Unable to copy $src to $dest: $!");
        }
    }

    return;
}

sub checkIfNewerVersion {
    my $existingScriptFile = shift;
    open( FILE, $existingScriptFile );
    if ( grep { /SCRIPT_VERSION/ } <FILE> ) {

        #return false for now, should call -version and compare
        return 1;
    }
    else {

        #existing perl script in serviceDir doesn't exist so should upgrade
        return 1;
    }
    close FILE;

}

# install it, backing up any existing files
sub installTestfix {
    info("Installing fix for $aparNum");

    # check our list if the APAR is installed and throw a message if it is
    # already installed
    my $found = 0;
    my $aparName;

    # make sure aparlist is non-empty before trying to check
    if ( -s $aparList ) {
        open( ALIST, "<$aparList" ) or fatal("Could not open $aparList: $!");
        while ( ( $found == 0 ) && ( $aparName = <ALIST> ) ) {
            chomp $aparName;
            if ( $aparName =~ m/^$fixName$/ ) {
                $found = 1;
            }
        }

        close ALIST;
    }

    if ($found) {
        warning("Fix $fixName already installed");
        info(
            "Please remove $fixName by rerunning this script with -remove
      option"
        );
        exit(1);
    }

    if ( !-d $backupDir ) {

        # not much can be done if we can't create a backup directory
        mkdir $backupDir or fatal(
            "Unable to create backup directory for APAR
      $aparNum at $backupDir"
        );
    }

    my $testfixContents = listTestfixContents($tarball);

    #check not run on file in service directory
    if ( $tarball =~ m/\Q$serviceDir\E/i ) {
        warning(
"You cannot run install on an fix archive in the service directory as it may be overwritten by a backup of the same name."
        );
        info(
"Please move the archive out of the service directory and rerun install.  If you were trying to remove the fix you need to run remove on an entry in the list of fixes"
        );
        listTestfixes();
        return;
    }

#check contents don't contain ncp_testfix.pl, indicating the wrapping archive was passed as an argument
    if ( contentsIndicateWrappingArchive($testfixContents) ) {
        warning("Archive $tarball may be the incorrect archive.");
        info(
"Please confirm $tarball is the correct archive to extract, check the filelist above."
        );
        return;
    }

#check if contents reflect the -core (precision path), -gui (profiles path) or #TODO -tcr (reports)
    if ( !contentsMatchFlag($testfixContents) ) {
        warning(
"Fix $fixName doesn't seem to be a fix for the provided core/gui/tcr flag"
        );
        info(
"Please confirm the type of fix and check the core/gui/tcr flag is correct"
        );
        if ( !getyn( "Do you wish to continue?", "y" ) ) {
            return;
        }
    }

    # store the list of files so we can use during remove
    my $filelist = "$backupDir/.filelist";
    open( FLIST, ">$filelist" ) or fatal("Could not open $filelist");

    foreach my $entry (@$testfixContents) {
        print FLIST $entry;
        print FLIST "\n";
    }
    close FLIST;

    backupExistingFiles($testfixContents);
    info("Backup complete");

    if ( !removeExistingFiles($testfixContents) ) {
        rollback();
        return;
    }

    if ( !unpackTestfixFiles($tarball) ) {
        rollback();
        return;
    }

    info("Files Upgraded");

    # we need to store the name of the APAR for listing & remove purposes
    #
    if ( !open( ALIST, ">>$aparList" ) ) {
        warning("Cannot open $aparList for append");
        cleanUp();
    }
    else {
        print ALIST $fixName . "\n";
        close ALIST;
    }

    # copy the README
    copyReadme();

    info("APAR $aparNum installed successfully");
}

sub rollback {
    my $backupArchive;

    # need to rollback the installed files
    if ($zipFile) {
        $backupArchive = "$backupDir/$fixName.zip";
    }
    else {
        $backupArchive = "$backupDir/$fixName.tar";
    }

    if ( -f $backupArchive ) {
        warning(
            "System in an unknown state, please extract $backupArchive to
      restore original files"
        );
    }
    else {

        # not much we can do, warn and exit
        warning(
            "Backup Archive $backupArchive does not exist, not rolling back
      files"
        );
    }
}

sub copyReadme {

    # we will assume that the README exists in the fixDir (dir where the tarball
    # was) in some form
    if ( -d $fixDir ) {
        my $files;
        if ($readdir) {
            $files = RIV::ReadDir($fixDir);
        }
        else {
            opendir( DIR, $fixDir ) or die "Could not open $fixDir";
            my @filesArray = readdir(DIR);
            closedir DIR;
            $files = \@filesArray;
        }

        foreach (@$files) {
            next if ( ( $_ eq "." ) or ( $_ eq ".." ) );
            if ( $_ =~ m/^.*readme.*$/i ) {
                my $readme   = $_;
                my $srcFile  = "$fixDir/$readme";
                my $destFile = "$backupDir/$readme";

                # found it, now copy it to the backup dir
                copy $srcFile, $destFile
                  or warning("Unable to copy $srcFile: $!");
            }
        }
    }

    return;
}

# We backup any existing files before overwriting them with the contents
# of the testfix
sub backupExistingFiles {
    my $filesToBackup = shift;

    chdir $rootDir
      || fatal("Failed to change to directory $rootDir");

    if ($zipFile) {
        my $notEmpty = 0;
        my $backup   = Archive::Zip->new();
        foreach my $fileToBeExtracted (@$filesToBackup) {
            if ( -f $fileToBeExtracted ) {
                $backup->addFile($fileToBeExtracted);
                $notEmpty = 1;
            }
        }

        if ($notEmpty) {
            my $backupZip = "$backupDir/$fixName.zip";
            my $status    = $backup->writeToFileNamed($backupZip);
            $status == AZ_OK or fatal("Could not write to $backupZip: $!");
        }

        chdir $startDir
          || fatal("Failed to change back to initial directory $startDir");
        return;
    }

    my $backup = Archive::Tar->new();

 # Although we could add all files in one fell swoop, we check if they
 # exist first. But some files in the testfix will be new files, and so will not
 # will not exist in the current installation. If we try to make a backup, we'll
 # get an error message.
    foreach my $fileToBeExtracted (@$filesToBackup) {

        # We tar up any files that already exist. And if tarring up a link,
        # we need to also grab what it points to, otherwise we won't be able
        # to restore it later on, due to the way Archive::Tar works
        if ( -f $fileToBeExtracted || -l $fileToBeExtracted ) {
            $backup->add_files($fileToBeExtracted);

            # Double-check it
            fatal(
                "Failed to add $fileToBeExtracted to a backup tarball. Please
            check permissions and try again."
              )
              unless $backup->contains_file($fileToBeExtracted);

            my ($tarredFile) = $backup->get_files($fileToBeExtracted);

            # Do th eextra link stuff, as mentioned above
            if ( $tarredFile->is_symlink() ) {
                my $dir     = dirname($fileToBeExtracted);
                my $linksTo = $tarredFile->linkname();

                my $additionalBackupFile =
                  File::Spec->catfile( $dir, $linksTo );

                $backup->add_files($additionalBackupFile);

                # Double-check it
                fatal(
                    "Failed to add $additionalBackupFile to a backup tarball.
              Please check permissions and try again"
                  )
                  unless $backup->contains_file($additionalBackupFile);
            }
        }
    }

    chdir $backupDir
      || fatal("Failed to change to backup directory $backupDir");

    my $backupTar = "$backupDir/$fixName.tar";
    $backup->write($backupTar);

    chdir $startDir
      || die "Failed to change back to initial directory $startDir\n";
}

# Extract the files from the testfix tarball to the home directory
sub unpackTestfixFiles {
    my ( $tarballName, $isBackupZip ) = @_;

    if ( $zipFile || ( defined $isBackupZip && $isBackupZip == 1 ) ) {
        my $zipFile = Archive::Zip->new();
        $zipFile->read($tarballName);
        info("Extracting $tarballName to $rootDir");

        my $status;

        #
        # testfix will be of form
        # IV00182.Windows.V39.32/precision/platform/win32/bin
        # while the backup file will be of form
        # precision/platform/win32/bin
        if ( defined $isBackupZip && ( $isBackupZip == 1 ) ) {
            $status = $zipFile->extractTree( "", "$rootDir/" );
        }
        else {
            $status = $zipFile->extractTree( $fixName, $rootDir );
        }

        $status == AZ_OK
          or do {
            warning("Unable to extract $tarballName: $!");
            return 0;
          };

        chdir $startDir
          || fatal("Failed to change back to initial directory $startDir");
        return 1;
    }

    # Note: we've got IO::Zlib, so this works even if the tarball is gzipped
    my $testfix = Archive::Tar->new();

# Prevent using stored UID otherwise extracting as root will change ownership to UID inside tar file
    $Archive::Tar::CHOWN = 0;

    $testfix->read($tarballName);

    chdir $rootDir
      || fatal("Failed to change to directory $rootDir");

    # Although the man page for extract states that it returns a list of
    # file names, it appears to return a list of Archive::Tar::File references
    # so we won't trust it, and do a long-winded check instead

    $testfix->extract()
      or do {
        warning("unable to extract $tarballName");
        return 0;
      };

    my @label = ('name');
    foreach my $testfixFile ( $testfix->list_files( \@label ) ) {
        if ( !-e $testfixFile ) {
            warning(
                "Failed to install $testfixFile from $tarballName. Suggest
          restoring the contents of the backup directory"
            );
            return 0;
        }

#        info ("installed testfix version of $testfixFile\n") if (! -d $testfixFile);
    }

    chdir $startDir
      || fatal("Failed to change back to initial directory $startDir");
    return 1;
}

# Rather than simply overwriting files, we remove them (having already backed them up)
# to avoid surprises with links. We only remove once we've got a backup, to ensure that
# we can restore the initial state
sub removeExistingFiles {
    my $backedUpFiles = shift;

    chdir $rootDir
      || fatal("Failed to change to directory $rootDir");

    my $removeFile;
    foreach my $fileToBeRemoved (@$backedUpFiles) {
        if ( $fileToBeRemoved =~ /\.*\n$/ ) {
            chomp $fileToBeRemoved;
        }

        if (   ( $fileToBeRemoved =~ /^$fixName\\(.*)/ )
            or ( $fileToBeRemoved =~ /^$fixName\/(.*)/ ) )
        {
            $fileToBeRemoved = $1;
            print $fileToBeRemoved . "\n";
        }

        # As this call removes files recursively, we need to be careful not
        # to remove directories
        if ( -f $fileToBeRemoved || -l $fileToBeRemoved ) {
            info("Removing file $fileToBeRemoved");

            rmtree($fileToBeRemoved)
              or do {

                # Double-check it
                warning(
                    "Failed to remove $fileToBeRemoved. Please check permissions
                  and try again."
                );
                return 0;
              };
        }
    }

    chdir $startDir
      || fatal("Failed to change back to initial directory $startDir");
    return 1;
}

# Get a tarball of the files from before the testfix, that were
# backed up when the testfix was installed
sub getBackedUpFiles {
    my $testfixFiles = shift;

    chdir $rootDir
      || fatal("Failed to change to directory $rootDir");

    fatal(
        "Cannot automatically remove installed fix, as backup directory
      '$backupDir' could not be found"
      )
      unless -d $backupDir;

    chdir $backupDir
      || fatal("Failed to change to backup directory $backupDir");

    my $original = Archive::Tar->new();

    foreach my $fileToRetrieve (@$testfixFiles) {

 # Check if we need to backup a file that already exists. We ignore directories,
 # as they'll be pulled in when we tar up anything within them
        if ( -e $fileToRetrieve && !-d $fileToRetrieve ) {
            $original->add_files($fileToRetrieve);

            # Double-check it
            fatal(
                "Failed to retrieve $fileToRetrieve from backup directory
              $backupDir. Please check permissions and try again."
              )
              unless $original->contains_file($fileToRetrieve);
        }
    }

    chdir $startDir
      || fatal("Failed to change back to initial directory $startDir");

    return $original;
}

# Back out a previously installed test fix
sub removeTestfix {
    info("Removing APAR $fixName");

    if ( -z $aparList ) {

        # file has zero size
        fatal("APAR List file $aparList is empty");
    }

    my $latestFix;
    open( ALIST, "$aparList" ) or fatal("Unable to open $aparList");
    while (<ALIST>) {
        chomp;
        $latestFix = $_;
    }
    close ALIST;

    if ( $fixName ne $latestFix ) {
        warning(
"uninstalling fixes in an order different from the installation order may cause the system to be in an unknown state",
        );
        if ( !getyn( "Do you wish to continue?", "y" ) ) {
            return;
        }
    }

    fatal(
        "backup directory $backupDir does not exist, this fix cannot be
    removed"
      )
      unless ( -d $backupDir );

    my $backupTar = "$backupDir/$fixName.tar";
    my $backupZip = "$backupDir/$fixName.zip";
    my $noBackup  = "0";

    # nobackup can take 3 values
    # 0 - indicates no files were backed up
    # 1 - indicates a .zip file (Windows)
    # 2 - indicates a .tar file
    if ( -f $backupTar ) {
        $noBackup = 2;
        if ( checkIfEmpty($backupTar) ) {
            $noBackup = 0;
        }
    }
    elsif ( -f $backupZip ) {
        info("Backup is a zip file");
        $noBackup  = 1;
        $backupTar = $backupZip;
    }
    else {
        info("no backups found");
    }

    my $filelist = "$backupDir/.filelist";
    fatal("filelist $filelist does not exist") unless ( -f $filelist );

    my @installedFiles;
    open( FLIST, "$filelist" ) or fatal("Could not open $filelist");
    @installedFiles = <FLIST>;
    close FLIST;

    # remove everything in .filelist
    if ( !removeExistingFiles( \@installedFiles ) ) {
        rollback();
        return;
    }

    info("Files removed successfully");

    # restore the files that were backed up
    if ( $noBackup > 0 ) {
        if ( !unpackTestfixFiles( $backupTar, $noBackup ) ) {
            rollback();
            return;
        }
    }
    else {
        info("No Files to restore");
    }

    deleteAparFromList();
    info("Fix $fixName removed successfully");

    if ( !deleteDirectory($backupDir) ) {
        manualCleanup("Unable to delete $backupDir");
    }
}

# List the files in the testfix (including any links and directories)
# Returns the list
sub listTestfixContents {
    my $tarballName = shift;
    if ($zipFile) {
        my $testfix = Archive::Zip->new();
        $testfix->read($tarballName);
        my @filelist = $testfix->memberNames();
        my @newFileList;
        foreach my $t (@filelist) {
            $t =~ /^$fixName[\\|\/](.*)/;
            print "$1\n";
            push @newFileList, $1;
        }

        return \@newFileList;
        exit;
    }

    # Note: we've got IO::Zlib, so this works even if the tarball is gzipped
    my $testfix = Archive::Tar->new();
    $testfix->read($tarballName);

    # Just pull out the names of the files (including directories and links)
    my @label    = ('name');
    my @fileList = $testfix->list_files( \@label );

    print "\n########################################################\n";
    print "Fix package $tarballName contains:\n";
    foreach my $file (@fileList) {
        print "$file\n";
    }
    print "########################################################\n\n";

    return \@fileList;
}

sub contentsMatchFlag {

    #maybe this is enough for contentsIndicateWrappingArchive also
    my $filelist = shift;

    #print "tcrApar=$tcrApar, \$guiApar =$guiApar, \$coreApar = $coreApar\n";
    if ( ($tcrApar) && ( $filelist->[0] =~ m/TCRComponent/i ) ) {
        return 1;
    }
    elsif ( ($guiApar) && ( $filelist->[0] =~ m/profiles/i ) ) {
        return 1;
    }
    elsif ( checkCoreFix( $coreApar, $filelist ) ) {
        return 1;
    }
    else {
        return 0;
    }

}

sub contentsIndicateWrappingArchive() {
    my $filelist = shift;
    foreach (@$filelist) {
        if ( $_ =~ m/ncp_testfix.pl/i ) {
            warning(
"ncp_testfix.pl found inside the archive.  It should only contain files for extraction to \$NCHOME or \$TIPHOME."
            );
            return 1;
        }

    }
}

sub checkIfEmpty {
    my $archive = shift;
    my $tar     = Archive::Tar->new();
    $tar->read($archive);
    my @label = ('name');
    my @files = $tar->list_files( \@label );
    if (@files) {
        return 0;
    }

    info("$archive is empty");
    return 1;
}

sub deleteEntryFromFile {
    my $origfile = shift;
    my $line     = shift;
    my $tmpFile  = "$serviceDir/tmpfile.$$";
    open( TMPFILE, ">$tmpFile" )
      or manualCleanup("Manually edit $origfile and remove  entry for $line");
    open( FILE, "<$origfile" )
      or manualCleanup("Manually edit $origfile and remove  entry for $line");
    while (<FILE>) {
        chomp $_;
        my $tmpline = $_;
        if ( $tmpline !~ m/^$line/ ) {
            print TMPFILE $tmpline . "\n";
        }
    }

    close TMPFILE;
    close FILE;

    move $tmpFile, $origfile
      or die("Manually edit $origfile and remove the entry for  $line");
}

sub deleteAparFromList {

    # lets remove the the APAR from the list of APARs
    deleteEntryFromFile( $aparList, $fixName );
}

# List the files in the testfix (including any links and directories)
# Returns the list
sub listTestfixes {
    if ( ( -e $aparList ) && ( -s $aparList ) ) {

        {
            comment(
                "",
                "***********************************",
                "***** List of installed fixes *****",
                "***********************************",
                ""
            );
            open( ALIST, "<$aparList" )
              or fatal("Could not open $aparList: $!");
            while (<ALIST>) {
                chomp $_;
                print $_ . "\n";
            }
            close ALIST;
            comment( "", "***********************************" );
        }
    }
    else {
        warning("Fix List $aparList is empty");
    }
    return;
}

################################################
# Helper subroutines
################################################

# Make a backup copy of a file.
# Pre-requisite: file name passed in refers to a file, as opposed to
#                a directory or a link
sub backupFile {
    my $fileName = shift;

    my $backupSuffix = "backup";

    # we can use this if a file with the name of the backup already exists
    my $extraSuffix = 1;

    my $backup = "$fileName.$backupSuffix";

    while ( -e $backup ) {
        $backup = "$fileName.$backupSuffix.$extraSuffix";
        ++$extraSuffix;
    }

    comment( "", "Backing up file $fileName as $backup", "" );
    copy $fileName, $backup;
}

sub checkPrereqs {

    # if corefilelist exists then its a core APAR, else a GUI/TIP APAR
    if ( -e $coreList ) {
        $filelist = $coreList;
        $coreApar = 1;
    }
    elsif ( -e $guiList ) {
        $filelist = $guiList;
        $guiApar  = 1;
    }
    else {
        comment(
            "",
"***** FATAL: Neither of the file lists $coreList nor $guiList exists  *****",
            ""
        );

        exit;
    }
}

sub getUserInfo {
    $userName = getlogin || getpwuid($<);
}

sub getAparInfo {
    info("Installing fix supplied as $tarball");
    my $fileName = basename $tarball;

    # we assume that the APAR testfix directory is named in form
    # IV12461.Platform.V39.32.tar

    $fixName = basename $tarball;
    if ( $fixName !~ /(.*)\.(.*)\.(.*)\.(.*)\./ ) {
        fatal("Fix Name is not in expected format FIXNUM.Platform.Ver.Build");
    }
    else {
        $aparNum    = $1;
        $platform   = $2;
        $version    = $3;
        $buildLevel = $4;
    }

    $currentOS = $^O;

    if ( !verifyOS( $currentOS, $platform ) ) {
        fatal("This fix is for $platform while the current OS is $currentOS");
    }

    $fixName =~ m/(.*)\.(.*)$/;
    if ( $2 eq "gz" or $2 eq "tar" ) {
        $zipFile = 0;
    }
    elsif ( $2 eq "zip" ) {
        comment( "", "ZIP file", "" );
        $zipFile = 1;
    }
    else {
        fatal("$tarball is in an unsupported format");
    }

    comment( "", "Fix Number is $aparNum and build level is $buildLevel", "" );

    $fixName = "$aparNum.$platform.$version.$buildLevel";

    # we will assume that the README file is in the same dir as the tar/zip file
    $fixDir = dirname $tarball;
}

sub verifyOS {
    my $currentOS = shift;
    my $platform  = shift;

    #in zLinux currentOS is Linux so need to check for s390
    my $architectureName = $Config{'archname'};

    if ( $currentOS !~ m/$platform/i ) {

        if ( checkWindows( $platform, $currentOS ) ) {
            return 1;
        }
        elsif ( $platform =~ m/platformall/i ) {
            return 1;
        }

        #in zLinux currentOS is Linux so need to check for s390
        elsif (( $currentOS =~ m/linux/i )
            && ( $architectureName =~ m/s390/i ) )
        {
            return 1;
        }
        else {
            return 0;
        }
    }

    return 1;
}

################################################
# Handling cmd line arguments
################################################

# Process the cmd line args, and do the appropriate work.
sub processCmdLine {

    # We need at least one cmd line arg
    printUsage() unless (@ARGV);

    #Don't call exit function in printUsage to enable unit testing
    return 1 unless (@ARGV);

    @scriptArgs = @ARGV;

    my ( $install, $remove, $core, $gui, $tcr, $list, $help, $version );

    GetOptions(
        "install:s" => \$install,
        "remove:s"  => \$remove,
        "core"      => \$core,
        "gui"       => \$gui,
        "tcr"       => \$tcr,
        "list"      => \$list,
        "help"      => \$help,
        "version"   => \$version
    );

    if ( defined $help ) {
        printHelp();
    }
    if ( defined $version ) {
        printVersion();
    }

    # Check we know where to put the testfix files
    my $topLevelEnvVar = "NCHOME";
    fatal("Environment variable $topLevelEnvVar must be defined")
      unless exists $ENV{$topLevelEnvVar};

    my $tipEnvVar = "TIPHOME";

    $nchomeDir = $ENV{$topLevelEnvVar};

    # if NCHOME is set but is null then exit
    fatal("NCHOME dir $nchomeDir does not exist") unless ( -d $nchomeDir );

    #
    # by default root dir is the nchome directory
    # unless its a GUI testfix, in which case it will be TIPHOME
    #
    $rootDir      = $nchomeDir;
    $precisionDir = "$ENV{$topLevelEnvVar}/precision";
    $serviceDir   = "$nchomeDir/service";

    createServiceDir();
    $aparList = "$serviceDir/aparlist";
    $logfile  = "$serviceDir/.install.log.$$";

    if ( defined $list ) {
        listTestfixes();
        tidyUp();
        exit(1);
    }

    fatal("-install or -remove must be specified")
      unless ( defined $install or defined $remove );

    # ignore for now
    # checkPrereqs();
    #
    if ( defined $install ) {
        $tarball = $install;

        # Check we have the required access to the testfix
        fatal("Could not locate test fix package called '$tarball'")
          unless ( -f $tarball );
        fatal("Require read access to test fix package $tarball")
          unless ( -r $tarball );
        getAparInfo();
    }
    else {
        $fixName = $remove;
        fatal("Please specify an fix to be removed") if ( $remove eq "" );
    }

    fatal("-core , -gui or -tcr must be specified")
      unless ( defined $core or defined $gui or defined $tcr );

    if ( defined $core ) {
        $coreApar = 1;
    }
    if ( defined $gui ) {
        $guiApar = 1;
    }
    if ( defined $tcr ) {
        $tcrApar = 1;
    }

    $backupDir = "$nchomeDir/service/$fixName";

    if ( $guiApar == 1 or $tcrApar == 1 ) {
        fatal("Environment variable $tipEnvVar must be defined")
          unless exists $ENV{$tipEnvVar};
        $rootDir = $ENV{$tipEnvVar};
        if ( $tcrApar == 1 ) {
            $rootDir = "$rootDir/../tipv2Components";
        }

        # if TIPHOME is set but is null then exit
        fatal("TIPHOME dir $rootDir does not exist") unless ( -d $rootDir );
    }

    getUserInfo();
    checkPerl();

    if ( defined $remove ) {
        removeTestfix();
        tidyUp();
        exit(1);
    }

    if ( defined $install ) {
        installTestfix();
        tidyUp();

        # if not running as root, then warn the user to run
        # setup_run_as_setuid_root.sh script
        if ( $userName ne "root" && !$guiApar && !checkWindows("windows",$^O) ) {
            warning(
"Please run $nchomeDir/precision/scripts/setup_run_as_setuid_root.sh as root to complete installation"
            );
        }
        exit(1);
    }
}

sub tidyUp {

    # delete the log file
    if ( -f "$logfile" ) {
        unlink $logfile or warning("Unable to delete $logfile: $!");
    }
}

sub cleanUp {
    open( FLIST, "<$filelist" )
      or manualCleanup("Unable to open $filelist:$!");
    while ( my $line = <FLIST> ) {
        chomp $line;
        my $destFile = "$rootDir/$line";
        my $fileName = basename $line;
        my $srcFile  = "$backupDir/$fileName";
        if ( -f $srcFile ) {
            copy $srcFile, $destFile
              or manualCleanup("Unable to copy $srcFile to  $destFile: $!");
        }
    }
    close FLIST;

    exit;
}

sub manualCleanup {
    warning(@_);
    die(
"System in Unknown state.  Use screen output to repair to original state"
    );
}

sub deleteDirectory {
    my $dir = shift;

    if ( -d $dir ) {
        my $files;
        if ($readdir) {
            $files = RIV::ReadDir($dir);
        }
        else {
            opendir( DIR, $dir ) or die "Could not open $dir";
            my @filesArray = readdir(DIR);
            closedir DIR;
            $files = \@filesArray;
        }

        foreach (@$files) {
            next if ( ( $_ eq "." ) or ( $_ eq ".." ) );
            my $file = "$dir/$_";
            unlink $file or warning("Unable to delete $file: $!");
        }

        rmdir $dir or die "Unable to delete $dir: $!";
        return 1;
    }

    return 0;
}

sub info {
    comment( "", "***** INFO: @_ *****", "" );
}

sub warning {
    comment( "", "***** WARNING: @_ *****", "" );
}

sub fatal {
    warning(@_);
    exit(2);
}

=head3 ask

Print the first argument without a newline with any
optional default (second argument) in square brackets
Read STDIN and return the chomped answer

If a blank answer is allowed, set argument2 to ""

=cut 

sub ask {
    my ( $question, $default, $vetsub ) = @_;

    # Was a default supplied
    if ($default) {
        $question .= " [$default]";
    }

    logmsg(":Q: $question ?");
    while (1) {
        print "$question : ";
        my $answer = <STDIN>;
        $answer =~ s/[\r\n]*$//;    #  Multi-OS chomp
        if ( $answer =~ /^\s*$/ ) {
            if ( defined($default) ) {
                logmsg(":D: $default");
                return $default;
            }
            print "No default answer defined!\n";
            next;
        }
        next if ( defined($vetsub) && !&{$vetsub}($answer) );
        logmsg(":A: $answer");
        return $answer;
    }
}

=head3 getyn

Print the first argument without a newline with any
optional default Y or N in square brackets
Read STDIN and return T/F

=cut

sub getyn {
    my ( $question, $default ) = @_;
    croak("Default not Y|N")
      if ( defined($default) && $default !~ /[yn]/i );

    my $yn = ask(
        $question,
        $default,
        sub {
            return 1 if ( $_[0] =~ /^\s*(y(es)?|no?)\s*$/i );
            print "(y)es or (n)o please!\n";
            return 0;
        }
    );

    return ( $yn =~ /^\s*y(es)?\s*$/i );
}

=head3 comment

Print the arguments appending a newline to each argument
Also log the arguments to the logfile, appending a newline to each argument

=cut

sub comment {
    logmsg(@_);
    while (@_) {
        print shift, "\n";
    }
}

=head3 logmsg

Log the arguments to the logfile, appending a newline to each argument

=cut

sub logmsg {
    if ( defined($logfile) && ( -d $serviceDir ) ) {
        open( LOGFILE, ">>$logfile" );
        while (@_) {
            print LOGFILE shift, "\n";
        }
        close LOGFILE;
    }
}

sub printUsage {
    print qq(
Usage: ncp_textfix.pl [-help] [-remove <fix name>  <-core|-gui|-tcr> ] [-install <fix archive>
<-core|-gui|-tcr> ] [-list]

);

    #Don't call exit function in printUsage to enable unit testing
    #exit(1);
}

sub printHelp {
    print qq(
######################################################
   ncp_textfix.pl [-help] [-remove <fix archive>  <-core|-gui|-tcr> ] [-install <fix archive>
   <-core|-gui> ] [-list]
######################################################

This script can be used to install appropriately bundled
 fixes for Precision IP / IBM Tivoli Network Manager.

Usage examples
--------------

Installing a fix package:
    ncp_testfix.pl -install 

Uninstalling an installed fix package:
    ncp_testfix.pl -remove

Arguments
---------
[-help]     Print this message.

[-install] Install a fix, the path to the fix archive is expected to follow
[-remove]  Remove an installed fix, and remove the original files.
           This requires the fix to have been installed with this script.
           The fix name is expected to follow

[-list]     List the fixes installed. No further actions
            will be performed.
[-core]   indicates that the fix is for core ITNM 
[-gui]    indicates that the fix is for Web Component/TIP
[-tcr]    indicates that the fix is for Reports

Results
-------

After installing a fix package, the original files are backed up 
in a backup directory in \$NCHOME, identifiable by the same name as
the fix package. 

After restoring a fix package, the contents of the backup directory
are returned to their original locations, and all fix related files are
removed.

Pre-conditions
--------------

(1) Environment variable \$NCHOME has been set.
(2) User has write access to \$NCHOME and its sub-directories.

);

    #exit(1);
}

sub printVersion() {
    print($SCRIPT_VERSION);
}

sub checkWindows {
    my $platform  = shift;
    my $currentOS = shift;

    # could be windows
    if ( ( $currentOS =~ m/mswin/i ) && ( $platform =~ m/windows/i ) ) {
        return 1;
    }
    return ();
}

sub checkCoreFix {
    my $coreApar = shift;
    my $filelist = shift;

    if ( ($coreApar) && checkFileList( $filelist, "precision" ) ) {
        return 1;
    }
    return ();
}

sub checkFileList {
    my $filelist      = shift;
    my $stringToCheck = shift;
    foreach my $t (@$filelist) {
        if ( $t =~ $stringToCheck ) {
            return 1;
        }
    }
}