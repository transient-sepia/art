#!/usr/bin/perl -w
#
# awr-chan
# version 1.1
#
# / aggh! you're thinking in japanese, aren't you? /
#

# use
use strict;
use Term::ReadKey;
use DBI;
use MIME::Lite;
use File::Path qw( make_path );
use POSIX qw(strftime);
use File::Basename;
use Archive::Zip qw(:ERROR_CODES :CONSTANTS);
use warnings;
use Getopt::Std;

# initial vars
my $help = "\n\tART - AWR Report Tool\n\n\tUsage: art.pl [-iht] -s <SID> -r <RECIPIENT> [-c <INTERVAL>]\n \
        <RECIPIENT> in: aaa, bbb\n \
        Default report type is html.\n \
        -c - specify custom interval in -i mode (in minutes). \
        -h - print this message. \
        -i - incremental reports. \
        -r - mail recipient. \
        -s - database name. \
        -t - text format.\n\n";
my %args;
my ($report_name,$snap1,$snap2,$gen,$from,$to,$flag,$sendto,$start,$end,$r_type,$int_check);
my @snap_array = ( );
getopts('ihr:s:tc:', \%args) or die "Input error. Use -h.\n";
my $instance = $args{s};
my $rec = $args{r};
my $c_int = $args{c};
if ($args{h}) { print $help; exit 1; }
if (!$args{s}) { print "Database name wasn't specified.\n"; exit 1; }
if (!$args{r}) { print "Mail recipient wasn't specified.\n"; exit 1; }
if ($args{c} && !$args{i}) { print "Custom interval can only be specified in -i mode.\n"; exit 1; }
my $date = strftime "%d.%m.%Y_%H.%M.%S", localtime;
my $datecmp = strftime "%d.%m.%y %H:%M", localtime;

# user specific
my $ohome = "/u01/app/oracle/product/11.2/db_1";
my $directories = "/u01/app/oracle/reports/".$instance."/".$date;

# variables and checks
if ($args{t}) { $r_type = 'text'; }
else { $r_type = 'html'; }

my ($snap,$sth,$next,@array);
my $count = 0;

if ($args{i}) { $flag = 1; }
else { $flag = 0; }

if ($rec eq "aaa") { $sendto = "aaa\@domain.com"; }
elsif ($rec eq "bbb") {$sendto = "bbb\@domain.com"; }
else { print "Unknown recipient.\n"; exit 2; }

# check for availability
my $cmd = $ohome."/bin/tnsping $instance | tail -1";
my @out = `$cmd`;
chomp @out;

if (grep/^OK/, @out) { 
   # do nothing
}
elsif (grep/timed out/, @out) { print "Instance $instance is not reachable.\n"; exit 1;}
elsif (grep/Failed to resolve/, @out) { print "Instance $instance does not appear to be in tnsnames.ora.\n"; exit 1;}
else { print "Unknown network error.\n"; exit 2; }

# request password
print "Enter password: ";
ReadMode('noecho');
chomp(my $password = <STDIN>);
ReadMode(0);
print "\n";

# test connection
my $dbh = DBI->connect( 'dbi:Oracle:'.$instance,"sys",$password, {ora_session_mode => 2, PrintError => 0}) || die "\nDatabase connection not made: $DBI::errstr";

# more variables
my $zip = Archive::Zip->new();

# standby check
my $scheck = q {
   select status from v$instance
};

my $dmode = $dbh->selectrow_array($scheck);
chomp($scheck);
if ($dmode ne "OPEN") {
   print "WARNING - Database $instance is $dmode. It should be opened.\n";
   exit 1;
}

# snapshot intervals
my $interval_query = q {
   select extract(day from a.snap_interval)*24*60 + extract(hour from a.snap_interval)*60 +
   extract(minute from a.snap_interval) from dba_hist_wr_control a, v$database b where a.dbid=b.dbid
};

my $interval = $dbh->selectrow_array($interval_query);
chomp($interval);
print "Snapshot interval for $instance: $interval mins.\n";

sub begin_date {
   print "Enter start date (DD.MM.YY HH24:MI): ";
   chomp($from = <STDIN>);
}

sub end_date {
   print "Enter end date (DD.MM.YY HH24:MI): ";
   chomp($to = <STDIN>);
}

sub to_comparable {
   my ($dcmp) = @_;
   my ($Y,$m,$d,$H,$M) = "";
   if ($dcmp =~ m/^[0-9]{2}\.[0-9]{2}\.[0-9]{2}\s{1}[0-9]{2}\:[0-9]{2}$/ ) {
      ($Y,$m,$d,$H,$M) = $dcmp =~ m{^([0-9]{2}).([0-9]{2}).([0-9]{2})\s{1}([0-9]{2}):([0-9]{2})\z};
   }
   else {
      ($Y,$m,$d,$H,$M) = ("00","00","00","00","00");
   }
   return "$Y$m$d$H$M";
}

# incremental reports
sub snaps_i {
   begin_date();
   while ( $from !~ m/^[0-9]{2}\.[0-9]{2}\.[0-9]{2}\s{1}[0-9]{2}\:[0-9]{2}$/ ) {
      while ( $from !~ m/^[0-9]{2}\.[0-9]{2}\.[0-9]{2}\s{1}[0-9]{2}\:[0-9]{2}$/ ) {
         print "Wrong date format.\n";
         begin_date();
      }
      while ( to_comparable($from) gt to_comparable($datecmp) ) {
         print "You are about to break the spacetime continuum.\n";
         begin_date();
      }
   }
   end_date();
   while ( $to !~ m/^[0-9]{2}\.[0-9]{2}\.[0-9]{2}\s{1}[0-9]{2}\:[0-9]{2}$/ ) {
      while ( $to !~ m/^[0-9]{2}\.[0-9]{2}\.[0-9]{2}\s{1}[0-9]{2}\:[0-9]{2}$/ ) {
         print "Wrong date format.\n";
         end_date();
      }
      while ( to_comparable($to) gt to_comparable($datecmp) ) {
         print "You are about to break the spacetime continuum.\n";
         end_date();
      }
   }

   my $snap_ids = qq {
      select snap_id from dba_hist_snapshot
      where end_interval_time between to_date('$from', 'DD.MM.YY HH24:MI') - 2/1440
      and to_date('$to', 'DD.MM.YY HH24:MI') + 2/1440 order by snap_id
   };

   $sth = $dbh->prepare($snap_ids);
   $sth->execute();
   $sth->bind_columns(undef, \$snap);

   @array = ( );

   while( $sth->fetch() ) {
      push(@array, $snap);
   }

   if (scalar @array == 0) {
      print "No snapshots were found for that date!\n";
      exit 2;
   }

   if ($args{c}) {
      my $int_check_q = qq {
         select round(((to_date('$to', 'DD.MM.YY HH24:MI') - to_date('$from', 'DD.MM.YY HH24:MI'))*24*60),0)
         from dual
      };
      $int_check = $dbh->selectrow_array($int_check_q); # or die $DBI::errstr;
      chomp($int_check);
      if ($int_check % $c_int != 0) {
         print "The range of dates should be a multiple of specified custom interval.\n";
         exit 1;
      }
      my $int_d = $c_int/$interval;
      for (grep { ! ($_ % $int_d) } 0 .. $#array) {
         #print "LINE: $array[$_]\n";
         push(@snap_array, $array[$_]);
      }

      pop(@snap_array);
      print "Creating reports...";
      foreach $snap1 (@snap_array) { 
         $snap2 = $snap1 + $int_d;
         #print "ID: $snap1, NEXT: $snap2\n";
         if ($args{t}) { $report_name = $directories."/awrrpt_".$snap1."_".$snap2.".txt"; }
         else { $report_name = $directories."/awrrpt_".$snap1."_".$snap2.".html"; }
         my $connect_string = "sys\/$password\@$instance as sysdba";
my $result = qx { $ohome\/bin\/sqlplus $connect_string <<EOF
alter session set nls_language = 'AMERICAN';
define begin_snap = $snap1
define end_snap = $snap2
define report_name = $report_name
define report_type = $r_type
\@$ohome/rdbms/admin/awrrpt.sql
exit
EOF
};
         $zip->addFile($report_name, basename($report_name));
      } 
      print " done.\n";
   }
   else {
      pop(@array);
      print "Creating reports...";
      foreach $snap1 (@array) {
         $snap2 = $snap1 + 1;
         #print "ID: $snap1, NEXT: $snap2\n";
         if ($args{t}) { $report_name = $directories."/awrrpt_".$snap1."_".$snap2.".txt"; }
         else { $report_name = $directories."/awrrpt_".$snap1."_".$snap2.".html"; }
         my $connect_string = "sys\/$password\@$instance as sysdba";
my $result = qx { $ohome\/bin\/sqlplus $connect_string <<EOF
alter session set nls_language = 'AMERICAN';
define begin_snap = $snap1
define end_snap = $snap2
define report_name = $report_name
define report_type = $r_type
\@$ohome/rdbms/admin/awrrpt.sql
exit
EOF
};
         $zip->addFile($report_name, basename($report_name));
      }
      print " done.\n";
   }
}

# by date reports
sub snaps {
   begin_date();
   while ( $from !~ m/^[0-9]{2}\.[0-9]{2}\.[0-9]{2}\s{1}[0-9]{2}\:[0-9]{2}$/ ) {
      while ( $from !~ m/^[0-9]{2}\.[0-9]{2}\.[0-9]{2}\s{1}[0-9]{2}\:[0-9]{2}$/ ) {
         print "Wrong date format.\n";
         begin_date();
      }
      while ( to_comparable($from) gt to_comparable($datecmp) ) {
         print "You are about to break the spacetime continuum.\n";
         begin_date();
      }
   }
   end_date();
   while ( $to !~ m/^[0-9]{2}\.[0-9]{2}\.[0-9]{2}\s{1}[0-9]{2}\:[0-9]{2}$/ ) {
      while ( $to !~ m/^[0-9]{2}\.[0-9]{2}\.[0-9]{2}\s{1}[0-9]{2}\:[0-9]{2}$/ ) {
         print "Wrong date format.\n";
         end_date();
      }
      while ( to_comparable($to) gt to_comparable($datecmp) ) {
         print "You are about to break the spacetime continuum.\n";
         end_date();
      }
   }

   my $snap_ids = qq {
      select min(snap_id),max(snap_id) from dba_hist_snapshot
      where end_interval_time between to_date('$from', 'DD.MM.YY HH24:MI') - 2/1440
      and to_date('$to', 'DD.MM.YY HH24:MI') + 2/1440 order by snap_id
   };

   $sth = $dbh->prepare($snap_ids);
   $sth->execute();
   $sth->bind_columns(undef, \$snap1, \$snap2);

   @array = ( );

   while( $sth->fetch() ) {
      push(@array, $snap1, $snap2);
   }

   if (!($snap1) || !($snap2)) {
      print "No snapshots were found for that date!\n";
      exit 2;
   }

   #print "ID: $array[0], NEXT: $array[1]\n";
   $snap1 = $array[0];
   $snap2 = $array[1];
   if ($snap1 == $snap2) {
      print "Invalid range (SNAP_IDs are the same).\n";
      exit 2;
   }
   if ($args{t}) { $report_name = $directories."/awrrpt_".$snap1."_".$snap2.".txt"; }
   else { $report_name = $directories."/awrrpt_".$snap1."_".$snap2.".html"; }
   print "Creating report...";
   my $connect_string = "sys\/$password\@$instance as sysdba";
my $result = qx { $ohome\/bin\/sqlplus $connect_string <<EOF
alter session set nls_language = 'AMERICAN';
define begin_snap = $snap1
define end_snap = $snap2
define report_name = $report_name
define report_type = $r_type
\@$ohome/rdbms/admin/awrrpt.sql
exit
EOF
};
   print " done.\n";
   $zip->addFile($report_name, basename($report_name));
}

# multiple reports
sub ask {
   print "Create AWR report? (y/[N]): ";
   chomp($gen = <STDIN>);
   if ($gen eq "y") {
      if ( !-d $directories ) {
         make_path $directories or die "Failed to create path: $directories\n";
      }
      if ($flag == 1) {
         snaps_i();
         ask();
      }
      else {
         snaps();
         ask();
      }
      $count = $count + 1;
   }
   #elsif ($gen eq "n") { $dbh->disconnect; }
   #elsif (length($gen) == 0) { ask(); }
   else { 
      #$dbh->disconnect;
      #print "Must use \"y\" or \"n\", exiting...\n";
      #exit 2;
      # do nothing
   }
}

# ctrl-c ctrl-d handling
$SIG{INT} = sub { die "\nCaught a sigint. $!.\n" };
$SIG{TERM} = sub { die "\nCaught a sigterm. $!.\n" };

# core
ask();

# even more variables
my $zipName = $directories."/".$date.".zip";

# check archive
if ($count != 0) {
   my $zipstatus = $zip->writeToFileNamed($zipName);
   if ($zipstatus != AZ_OK) {
      print "Error in archive creation!\n";
      exit 2;
   }
   else {
      print "Archive ".$date.".zip created successfully.\n";
   }

   # mail variables
   my $sender = "AWR\@domain.com";
   my $subject = "AWR Report(s) for $instance";
   my $message = "Zipped archive attached below:\n\n";

   # mail
   my $msg = MIME::Lite->new(
                 From     => $sender,
                 To       => $sendto,
                 Subject  => $subject,
                 Type     => 'multipart/mixed'
                 );
                 
   $msg->attach(Type         => 'text',
             Data         => $message
            );
            
   $msg->attach(Type        => 'application/zip',
             Path        => $zipName,
             Filename    => 'awr.zip',
             Disposition => 'attachment'
            );
   $msg->send or die "Couldn't send an email.\n";
   print "Email sent successfully.\n";
}
else {
  print "No AWR report was generated.\n";
}
