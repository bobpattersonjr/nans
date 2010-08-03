#!/usr/bin/perl -w
#
# BACKGROUND
# This is the companion to collate-notifications.pl.  It will periodically 
# read, clear, and process the notification file.  Run from cron.
# It is specifically designed for sites that receive many pages and that send 
# them all to the same few contacts.  The contacts we have set up in Nagios 
# are aliases for groups of people, for instance.  This is meant to supplement
# the built in notification functionality, not replace it.  You still need to 
# configure Nagios, set up your escalations, etc.
#
# CONFIGURATION
# Add the appropriate line to cron.  For instance:
# * * * * * /usr/local/nagios/bin/aggregate-notify.pl -t 2 -c '/usr/local/nagios/etc/notification-page.cfg' -f '/usr/local/nagios/var/rw/page-log.txt'
# * * * * * /usr/local/nagios/bin/aggregate-notify.pl -t 10 -c '/usr/local/nagios/etc/notification-email.cfg' -f '/usr/local/nagios/var/rw/email-log.txt'
# Use the -g flag to group notifications by hostgroup.
#
# Also, set your mailer of choice (I assume sendmail or a "sendmail-alike") in $mailer.
# Optionally, set $divider and $loglevel. 
# $loglevel 0 == no logs; $loglevel 1 == errors only;
# $loglevel 2 == errors and notifications; $loglevel 3+ == ridiculous verbosity
#
# ISSUES
# This might benefit from having  a threshold on the max number of entries
# to aggregate into a single email.  It also could be cleaner.
# I've changed my mind, I can't be bothered with ruling the world.  Maybe
# just a small tropical island would work.
#
# AUTHOR
# (c)2001 by Nicholas Tang <ntang@mail.communityconnect.com>
#
# UPDATED
# 2009 Bob Patterson <bpatterson -at- i1ops dot net>
#
# Assistance, ideas, and code snippets from a few people.  Major 
# contributors listed inline in comments.  Thanks, everyone!
########################################################################

use strict;
use Getopt::Std;
use FileHandle;

use vars qw($fh %opts $mail $page $mailer @config @services @hosts @ERRORS $divider $logfile 
            $loglevel $from $replyto %pagecount %fmt %mailh $debug);

use constant VERSION => 0.8;
use constant LOCK_EX => 2;
use constant LOCK_UN => 8;
use constant DEFAULT => 'default';
use constant SUBJECT => '=NANS=';

##### SET THESE VARIABLES #####
$mailer	= "/usr/lib/sendmail";
$divider = "\n|\n";
$logfile = "/usr/local/nagios/var/rw/nans.log";
$loglevel = 5;
$from = '';
$replyto = '';
$debug = 0;
#### STOP TOUCHING THINGS #####

%fmt = (
  'count'   =>
      {'title' => '',
       'host'  =>
          ["%s is %s - %s$divider", 'host', 'state', 'date'],
       'svc'   =>
          ["%s - %s is %s - %s$divider", 'host', 'serdesc', 'state', 'date'],
      },
  'tinysum'    =>
      {'title' => '',
       'host'  =>
          ["%s is %s - %s - %s$divider", 'host', 'state', 'date', 'ack'],
       'svc'   =>
          ["%s - %s is %s - %s - %s$divider", 'host', 'serdesc', 'state', 'date', 'ack'],
      },
  'summary'        =>
      {'title' => "***** Notification Summaries *****\n\n",
       'host'  =>
          ["%s - %s - %s (%s) - %s - %s - %s$divider", 'type', 'state', 'host', 'ip',
          'date', 'output', 'ack'],
       'svc'   =>
          ["%s - %s - %s (%s - %s) - %s - %s - %s$divider", 'type', 'state',
          'serdesc', 'host', 'ip', 'date', 'output', 'ack'],
      },
  'full'       =>
      {'title' => "***** Notification Details *****\n\n",
       'host'  =>
          ["Notification Type: %s\nHost: %s\nState: %s\nAddress: %s\n" .
           "Info: %s\nDate/Time: %s - %s\n\n", 'type', 'host', 'state', 'ip',
           'output', 'date', 'ack'],
       'svc'   =>
          ["Notification Type: %s\nService: %s\nHost: %s\nAddress: %s\n" .
           "State: %s\nDate/Time: %s\nAdditional Info:\n%s - %s\n\n", 'type',
           'serdesc', 'host', 'ip', 'state', 'date', 'output', 'ack'],
      },
);


getopts('gt:f:c:',\%opts);

unless ( ($opts{t}) && ($opts{f}) && ($opts{c}) ) {
  if ($loglevel > 1) { write_log("Script is missing arguments.  Quitting out now."); }
  warn "ERROR: missing arguments.  You can't miss an argument!\n\n";
  print_usage();
  exit 3;
}

my $timer	= $opts{t};
my $notifyfile	= $opts{f};
my $configfile	= $opts{c};
my $grouphosts	= $opts{g};

if ($loglevel > 2) { write_log("Beginning run with ridiculous verbosity engaged!"); }

if ($timer < 1) {
  push @ERRORS, "Timer must be greater-than or equal to 1!";
}

unless ( -s $configfile ) {
  push @ERRORS, "$configfile is empty!";
}
report_errors(@ERRORS);

parse_config($configfile);

unless ( -s $notifyfile ) {
  init_notfile($notifyfile);
  exit;
}

if ($loglevel > 2) { write_log("Configs read successfully.  Checking notification file."); }


########################################################
# This section checks the notification file, sees if it's 
# time to send out an aggregate notification or not, 
# and then either: decrements the counter by one, or 
# sends the notification out depending on what it finds.
########################################################
my @filelines;
my $timehandle = new FileHandle "< $notifyfile";
if ( defined($timehandle) ) {
  @filelines = <$timehandle>;
  $timehandle->close;
} else {
  push @ERRORS, "$notifyfile couldn't be opened for reading!";
}
report_errors(@ERRORS);

my $time_remaining = check_timer($filelines[0]);

my $inchandle = new FileHandle "> $notifyfile";
if ( defined($inchandle) ) {
  lockit($inchandle);
  $filelines[0] = decrement_timer($filelines[0]);
  foreach my $fileline (@filelines) {
    print $inchandle $fileline;
  }
  unlockit($inchandle);
  $inchandle->close;
} else {
  push @ERRORS, "$notifyfile could not be opened for writing!";
}
report_errors(@ERRORS);

if ($time_remaining) { 
  if ($loglevel > 2) { write_log("Time remaining ($time_remaining).  Exiting."); }
  exit;
}
if ($loglevel > 2) { write_log("Time to mail.  Checking for notifications to send."); }

########################################################
# This is where the notifications are sent out.  It 
# iterates through each contact in the config file and
# checks each notification line to see if that person
# matches it, and if so, it adds that notification 
# to the "body" of the email and sends it out when done.
########################################################
my $parsehandle = new FileHandle "< $notifyfile";
if ( defined($parsehandle) ) {
  parse_notifications($parsehandle);
  $parsehandle->close;
} else {
  push @ERRORS, "$notifyfile could not be opened for reading!";
}
report_errors(@ERRORS);

if ( ( defined(@services) ) || ( defined(@hosts) ) ) {

  if ($loglevel > 2) { write_log("Notifications found.  Sending now."); }

  foreach my $noteline (@services,@hosts) {
    my $contacthits = contact_defined($$noteline{contact});
    if ( $contacthits == 0 ) {
      push @ERRORS, "$$noteline{contact} is missing from $configfile!";
    } elsif ( $contacthits > 1 ) {
      push @ERRORS, "$$noteline{contact} is defined multiple times in $configfile!";
    }
  }
  report_errors(@ERRORS);

  foreach my $conf (@config) {
    my (%seen_title);
    undef (%mailh);

    if ( should_email($$conf{address}) ) {
      if ($loglevel > 1) { write_log("Match found for $$conf{address}.  Sending out notification."); }

      for my $type (keys %fmt) {
        if ( $$conf{$type} ) {
          my $contact = lc($$conf{address});

          if ($type eq 'count') {
            $mailh{DEFAULT} = init_mailhandle($contact, DEFAULT);
            for (keys %pagecount) {
              $mailh{DEFAULT}->print("$_ pages: $pagecount{$_}\n");
              if ($loglevel > 3) { write_log("Sending out $_ count."); }
            }
          $mailh{DEFAULT}->print("\n");
          }
          else {
            LINE: for my $line (@hosts, @services) {
              my $host = $grouphosts ? $$line{host} : DEFAULT;
              if ($contact ne $$line{contact}) { if ($loglevel > 3) { write_log("No match found for $contact."); } next LINE; }
              $mailh{$host} = init_mailhandle($contact, $host);
              if (! $seen_title{$host}{$type}++ ) {
                $mailh{$host}->print($fmt{$type}{'title'});
                if ($loglevel > 3) { write_log("Printing title."); }
              }
              if ( lc($$line{contact}) eq $contact ) {
                my $scope = $$line{serdesc} ? 'svc' : 'host';
                $mailh{$host}->printf(printf_args($line, $fmt{$type}{$scope}));
                if ($loglevel > 3) { write_log("Printing notification."); }
              }
            }
          }
        }
      }

      for (@hosts) { 
        if ( ref( $mailh{$$_{host}} ) ) { $mailh{$$_{host}}->close; }
      }
    }
  }
  wipeit($notifyfile);
}
elsif ( $loglevel > 2 ) {
  write_log("No notifications found.");
}
if ( $loglevel > 2 ) { 
  write_log("Run completed without errors.");
}
exit;

########################################################
########################################################
############  END MAIN - SUBROUTINES BELOW  ############
########################################################
########################################################

########################################################
# contact_defined checks the contact listed on the 
# notification line and makes sure there's a config 
# entry for it.
########################################################
sub contact_defined {
  my $contact = shift;
  my $matches = 0;
  foreach my $conf (@config) {
    if ( lc($$conf{address}) eq lc($contact) ) {
      $matches++;
    }
  }
  return($matches);
}

########################################################
# should_email takes an email address and then proceeds 
# to check all of the notifications in the "queue" and 
# see if any of them match.  If so, it returns true, 
# otherwise return false.
########################################################
sub should_email {
  my $email = shift;
  my $matches = 0;
  for (@services, @hosts) {
    if ( lc($$_{contact}) eq $email ) {
      $matches++;
    }
  }
  return($matches);
}

########################################################
# init_mailhandle uses an email address and hostname to 
# construct a pipe to our $mailer.  It returns a 
# FileHandle object containing the pipe.
# - Contributed by Alan Ritari.
########################################################
sub init_mailhandle {
  my ($email, $host) = @_;
  my $subject = SUBJECT;

  if (!exists($mailh{$host})) {
    $subject .= ($host && $host ne DEFAULT) ? " for $host" : '';

    $mailh{$host} = new FileHandle "| $mailer $email";
    if ( defined($mailh{$host}) ) {
      if ( defined($from) ) { $mailh{$host}->print("From: $from\n"); }
      if ( defined($replyto) ) { $mailh{$host}->print("Reply-To: $replyto\n"); }
      $mailh{$host}->print("To: $email\n");
      $mailh{$host}->print("Subject: $subject\n\n");
    } else {
      push @ERRORS, "Couldn't open pipe to $mailer!\n";
    }
  }

  report_errors(@ERRORS);
  return $mailh{$host};
}

########################################################
# parse_config reads in the provided config file and 
# (*gasp*) parses it out and fills in an array of 
# hashes with the info
########################################################
sub parse_config {
  my $conffile = shift;
  my $cfhandle = new FileHandle "< $conffile";
  if ( defined $cfhandle ) {
    while(<$cfhandle>) {
      my (%temphash,@temparray);
      if ( /^#/ || /^\s*$/ ) { next; }
      chomp;
      @temparray = split /,/;
      unless (@temparray == 5) {
        push @ERRORS, "Wrong number of fields on line $.";
      }
      foreach my $counter (1..4) {
        unless ( ( $temparray[$counter] == '1' ) || ( $temparray[$counter] == '0' ) ) {
          push @ERRORS, "Invalid field $counter of line $.";
        }
      }
      report_errors(@ERRORS);
      %temphash =
		(
		address	=> $temparray[0],
		count	=> $temparray[1],
		tinysum	=> $temparray[2],
		summary	=> $temparray[3],
		full	=> $temparray[4]
		);
      push @config,\%temphash;
    }
  } else {
    push @ERRORS, "Couldn't open $conffile for reading!";
  }
  report_errors(@ERRORS);
}

########################################################
# parse_notifications opens up the notifications file, 
# parses it, and "loads" three variables with the 
# appropriate data
########################################################
sub parse_notifications {
  my ($handle) = shift;
  while (<$handle>) {
    if ( /^#/ || /^\s*$/ ) { next; }
    chomp;
    if ( /^SERVICE/ ) {
      my %notifications;
      my @temparray = split(/\;/);
      unless (@temparray == 10) {
        push @ERRORS, "Incorrect format for service notification line.";
      }
      %notifications =	(
			contact	=> $temparray[1],
			date	=> $temparray[2],
			type	=> $temparray[3],
			ip	=> $temparray[4],
			host	=> $temparray[5],
			serdesc	=> $temparray[6],
			state	=> $temparray[7],
			output	=> $temparray[8],
			ack     => $temparray[9]
			);
      push @services,\%notifications;
    } elsif ( /^HOST/ ) {
      my %notifications;
      my @temparray = split(/\;/);
      unless (@temparray == 9) {
        push @ERRORS, "Incorrect format for host notification line.";
      }
      %notifications =	(
			contact	=> $temparray[1],
			date	=> $temparray[2],
			type	=> $temparray[3],
			ip	=> $temparray[4],
			host	=> $temparray[5],
			state	=> $temparray[6],
			output	=> $temparray[7],
			ack     => $temparray[8]
			);
      push @hosts,\%notifications;
    } else {
      push @ERRORS, "Error parsing notification file!  This is bad!";
    }
  report_errors(@ERRORS);
  }
}

########################################################
# init_notfile initializes an empty notification file, 
# which should only happen the first time you run it.
# If it happens any other time, it either means _I_
# suck... or _you_ do.  
# This is a stupid subroutine.
########################################################
sub init_notfile {
  my $initfile = shift;
  if ($loglevel > 0) { 
    write_log("$initfile not found, probably the first time this has been run.  Initializing $initfile now.");
  }
  wipeit($initfile);
}

########################################################
# check_timer opens up the notifications file and checks
# the "timer" to see if it's time to send out a page or 
# if it should just decrement it (ok, it's a counter, 
# not a timer) and end.
########################################################
sub check_timer {
  my $timeline = shift;
  my $ttm;
  if ( $timeline =~ /^#### ttm=(\d+)/ ) {
    $ttm = $1;
  }
  else {
    $ttm = ($timer - 1);
  }
  return($ttm);
}

########################################################
# decrement_timer is called if check_timer sees that it's 
# not yet time to send out the page.  Remember, if you 
# run this less frequently than every minute, that the 
# unit of time will no longer be one minute.
########################################################
sub decrement_timer {
  my $timeline = shift;
  my $ttm;
  if ( $timeline =~ /^\#\#\#\# ttm=(\d+)/ ) {
    $ttm = $1;
    if ( $ttm == 0 ) {
      $ttm = ($timer - 1);
    } elsif ( $ttm < 0 ) {
      push @ERRORS, "ttm is less than zero, $notifyfile may be corrupt!";
    } else {
      $ttm--;
    }
    $timeline = "#### ttm=$ttm timer=$timer DO NOT MODIFY THIS LINE ####\n";
  } else {
    push @ERRORS, "Ack, problem decrementing counter, $notifyfile may be corrupt!";
  }
  report_errors(@ERRORS);
  return($timeline);
}

########################################################
# printf_args accepts a hash reference to a notification
# line and an array reference to a printf format string
# and associate variable names.  It returns the format
# string and variable values such that they can be
# dropped right into a printf statement.
# - Contributed by Alan Ritari
########################################################
sub printf_args {
  my ($data, $arg_ref) = @_;
  my ($fmt, @vars, @args);
  @args = @$arg_ref;
  $fmt = shift(@args);
  @vars = map {$$data{$_}} @args;
  return ($fmt, @vars);
}

########################################################
# Wipeit clears the file that is passed to it of 
# everything but the counter line.
########################################################
sub wipeit {
  my ($wipefile) = shift;
  my $ttm = ($timer - 1);
  $fh = new FileHandle "> $wipefile";
  if (defined $fh) {
    lockit($fh);
    print $fh "#### ttm=$ttm timer=$timer DO NOT MODIFY THIS LINE ####\n";
    unlockit($fh);
    $fh->close;
  } else {
    push @ERRORS, "Couldn't open $wipefile for wiping!";
  }
  report_errors(@ERRORS);
  if ($loglevel > 2) { write_log("Wiping notification file."); }
}

########################################################
# Lockit locks the file, big surprise
########################################################
sub lockit {
  my ($handle) = shift;
  flock($handle,LOCK_EX);
  seek($handle,0,2);
  return 1;
}

########################################################
# Amazingly, unlockit unlocks the file
########################################################
sub unlockit {
  my ($handle) = shift;
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
  return unless @_;  	# return if there are no errors
  my(@errarray) = @_;
  foreach my $errorline (@errarray) {
    chomp; 		# superstition I guess...
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
# print_usage is yet another self-explanatory subroutine
########################################################
sub print_usage {
  my $version = VERSION;
  print "aggregate-notify.pl version $version\n";
  print "(c)2001 by Nicholas Tang under the GNU Public License (http://www.gnu.org/copyleft/gpl.txt)\n\n";
  print "Usage:\n";
  print "aggregate-notify.pl -f \'/path/to/notify/file\' -c \'/path/to/conf/file\' -t timer\n -g";
}
