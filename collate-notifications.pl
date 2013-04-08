#!/usr/bin/perl -w
#
# BACKGROUND
# This script will write all of the notifications nagios outputs to a file.
# Its sister script will read that file and email out the aggregate 
# notifications, to prevent your pager from melting down.
#
# OPERATION
# The command definition for notify-by-epager and host-notify-by-epager 
# need to be configured to use this script instead of echo'ing to mail.
# Its companion script needs a cron entry that runs it once per minute.
#
# CONFIGURATION
# Example configuration lines:
#
#define command{
#    command_name    notify-host-by-email
#    command_line    /usr/local/nagios/collate-notifications.pl -t 'HOST' -e '$CONTACTEMAIL$'  -d '$LONGDATETIME$' -n '$NOTIFICATIONTYPE$' -I '$HOSTADDRESS$' -H '$HOSTNAME$' -h '$HOSTSTATE$' -o '$HOSTOUTPUT$' -A '$HOSTNAME$' -a '$HOSTNAME$' -f '/usr/local/nagios/var/rw/email-log.txt'
#}
#define command{
#    command_name    notify-service-by-email
#    command_line    /usr/local/nagios/collate-notifications.pl -t 'SERVICE' -e '$CONTACTEMAIL$' -d '$LONGDATETIME$' -n '$NOTIFICATIONTYPE$' -I '$HOSTADDRESS$' -H '$HOSTNAME$' -S '$SERVICEDESC$' -s '$SERVICESTATE$' -o '$SERVICEOUTPUT$' -A '$HOSTNAME$' -a '$SERVICEDESC$' -f '/usr/local/nagios/var/rw/email-log.txt'
#}
#
#
# Also please note, I've added logging, so you need to configure that (if you want logging).
#
# ISSUES
# None that I'm aware of...!
#
# AUTHOR
# (c)2001 Nicholas Tang <ntang@mail.communityconnect.com>
#
# UPDATED                                                                                                                                                                                                     # 2009 Bob Patterson <bpatterson -at- i1ops dot net>
#######################################################################

use strict;
use Getopt::Std;
use FileHandle;

use vars qw($fh %opts $logfile $loglevel @ERRORS $debug $baseurl);
use constant VERSION => 0.8;
use constant LOCK_EX => 2;
use constant LOCK_UN => 8;

$baseurl = "http://nagios.*****.com/nagios/";
$logfile = "/usr/local/nagios/var/rw/nans.log";
$loglevel = 5;
$debug = 0;

getopt('fntHIodesShAa',\%opts);

unless ( ($opts{f}) && ($opts{n}) && ($opts{H}) && ($opts{I}) &&
         ($opts{o}) && ($opts{d}) && ($opts{e}) && ($opts{A}) && ($opts{a})) {
  push @ERRORS, "Not enough arguments. I like arguments.  GIVE ME MORE ARGUMENTS!!!";
  print_usage();
  report_errors(@ERRORS);
}

my $outfile = $opts{f};

if ($loglevel > 2) { write_log("Received notification.  Preparing to write out to notification file."); }

if ( $opts{t} eq 'SERVICE' ) {
  unless ( ($opts{s}) && ($opts{S}) ) {
    push @ERRORS, "Missing servicedesc or servicestate argument(s).";
    print_usage();
    report_errors(@ERRORS);
  }
  $fh = new FileHandle ">> $outfile";
  if (defined $fh) {
    lockit($fh);
    my $url = $baseurl."cgi-bin/cmd.cgi?cmd_typ=34&host=".$opts{A}."&service=".$opts{a};
    print $fh "$opts{t};$opts{e};$opts{d};$opts{n};$opts{I};$opts{H};$opts{S};$opts{s};$opts{o};$url\n";
    unlockit($fh);
    $fh->close;
  } else {
    push @ERRORS, "Couldn't append to $outfile!";
  }
  report_errors(@ERRORS);
}
elsif ( $opts{t} eq 'HOST' ) {
  unless ( $opts{h} ) {
    push @ERRORS, "Missing hoststate argument.";
    print_usage();
    report_errors(@ERRORS);
  }
  $fh = new FileHandle ">> $outfile";
  if (defined $fh) {
    lockit($fh);
    my $url = $baseurl."cgi-bin/cmd.cgi?cmd_typ=33&host=".$opts{A};
    print $fh "$opts{t};$opts{e};$opts{d};$opts{n};$opts{I};$opts{H};$opts{h};$opts{o};$url\n";
    unlockit($fh);
    $fh->close;
  } else {
    push @ERRORS, "Couldn't append to $outfile!";
  }
  report_errors(@ERRORS);
}
else {
  print_usage();
  exit 1;
}

if ($loglevel > 2) { write_log("Notification written without errors.  Exiting."); }
exit;

########################################################
########################################################
############  MAIN ENDS, SUBROUTINES BEGIN  ############
########################################################
########################################################

########################################################
# lockit gets a lock on the filehandle
########################################################
sub lockit {
  my ($handle) = @_;
  flock($handle,LOCK_EX);
  seek($handle,0,2);
  return 1;
}

########################################################
# unlockit removes the lock done by lockit
########################################################
sub unlockit {
  my ($handle) = @_;
  flock($handle,LOCK_UN);
  return 1;
}

########################################################
# report_errors ... reports errors... if there are any, 
# it will print them and die.  This acts as a break 
# point and also allows for more useful error reports.
#
# Thanks to Mark-Jason Dominus for this suggestion.
########################################################
sub report_errors {
  return unless @_;     # return if there are no errors
  foreach my $errorline (@_) {
    chomp ($errorline);              # superstition I guess...
    if ($loglevel > 0) { write_log("ERROR: $errorline"); }
    warn "ERROR: $errorline\n";
  }
  if ($loglevel > 0) { write_log("Quitting out due to errors."); }
  die "Quitting out due to errors.\n";
}

########################################################
# write_log writes things out to $logfile
########################################################
sub write_log {
  my($logline) = shift;
  chomp($logline);
  my($sec,$min,$hour,$mday,$mon,$year,undef,undef,undef) = localtime(time);
  $year = $year + 1900;
  $mon += 1;   
  $fh = new FileHandle ">> $logfile";
  if (defined $fh) {
    lockit($fh);
    printf $fh ("[%d-%02d-%02d %02d:%02d:%02d] [%s] %s\n",$year,$mon,$mday,$hour,$min,$sec,$$,$logline);
    if ($debug) { printf ("[%d-%02d-%02d %02d:%02d:%02d] [%s] %s\n",$year,$mon,$mday,$hour,$min,$sec,$$,$logline); }
    unlockit($fh);
    $fh->close;
  } else {
    die "Couldn't open $logfile for writing! $!\n";
  }
}

########################################################
# print_usage will print usage information
########################################################
sub print_usage {
  my $version = VERSION;
  print "\ncollate-notifications.pl version $version\n";
  print "(c)2001 by Nicholas Tang under the GNU Public License (http://www.gnu.org/copyleft/gpl.txt)\n\n";
  print "Usage:\n";
  print "collate-notifications.pl -t SERVICE -e email -d date -n notificationtype -I hostaddress -H hostname -S servicedesc -s servicestate -o output -f outfile\n";
  print "-or-\n";
  print "collate-notifications.pl -t HOST -e email -d date -n notificationtype -I hostaddress -H hostname -h hoststate -o output -f outfile\n\n";
}
