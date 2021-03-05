#! /usr/bin/perl

# Update to 0.1.1 -- Convert SQLite UTC timestamps to local time for display.

use strict;
use warnings;
use UI::Dialog;
use DBI;

use open ':std', ':encoding(utf8)';

{ my $ofh = select STDOUT;
    $| = 1;
    select $ofh;
}

my $db = DBI->connect("dbi:SQLite:dbname=Database/mealplan.sqlite") or die $DBI::errstr;
$db->{RaiseError} = 1;
$db->{sqlite_unicode} = 1; 
$db->{AutoCommit} = 1;

my $getuni = $db->prepare("SELECT UNI FROM ids WHERE id = ?");
my $getdiner = $db->prepare("SELECT UNI, Name, MealPlan, Affil from diners WHERE UNI = ?");
my $getmealcount = $db->prepare("SELECT count(*) FROM checkin WHERE UNI = ?");
my $addmealcheckin = $db->prepare("INSERT INTO checkin (UNI) VALUES (?)");
my $addcardno = $db->prepare("INSERT OR IGNORE INTO ids (id, UNI) VALUES(?,?)");
my $todaymealcount = $db->prepare("SELECT count(*) FROM checkin WHERE UNI = ? AND Timestamp LIKE date('now') || '%'");
my $prevcheckin = $db->prepare("SELECT datetime(Timestamp, 'localtime') FROM checkin WHERE UNI = ? ORDER BY Timestamp DESC LIMIT 1");

my $dialog = new UI::Dialog (title => "CUIMC MealPlan 0.1.1", height => "12");

#my $result = $dialog->inputbox( text => 'Please enter a UNI or card number:' );
my $message = 'Please enter a UNI or ID card number:';

my $beep = 0;
while(my $result = $dialog->inputbox( text => $message, beepbefore => $beep)) {

    $beep = 0;
    $message = 'Please enter a UNI or ID card number:';
    
    my $uni;
    my $name;
    my $mealplan;
    my $affil;

    $result = lc $result;

    if ($result =~ /\d{9}/ && $result !~ /\d{10}/) {
        $getuni->execute($result);
        #my $ref = $getuni->fetchrow_arrayref;
        #if (!defined $ref) {
        my $ref;
        unless ($ref = $getuni->fetchrow_arrayref) {
            unless ($uni = $dialog->inputbox( text => "\\Zb\\Zr\\Z1ID $result not found.\\Zn\n\nEnter UNI to save ID card number, or \\ZbCancel\\Zn to continue:", beepbefore => "1")) {
                $message = 'Please enter a UNI or ID card number:';
                $beep = 0;
                next;
            }
            #if ($uni eq 0) {next}
            $uni = lc $uni;
            $getdiner->execute($uni);
            my $ref = $getdiner->fetchrow_arrayref;
            if (!defined $ref) {
                $message = "\\Zb\\Zr\\Z1UNI $uni not found.\\Zn\n\nPlease enter a UNI or ID card number:";
                $beep = 1; 
                next;
            }
            $uni = $$ref[0];
            $name = $$ref[1];
            $mealplan = $$ref[2];
            $affil = $$ref[3];
            if ($dialog->yesno( text=> "Name: $name ($uni / $affil)\nCard: $result\n\nOK to link $result with $name?")) {
                $addcardno->execute($result,$uni);        
            } else {
                $message = "\\Zb\\Zr\\Z1ID Card not linked.\\Zn\n\nPlease enter a UNI or ID card number:";
                $beep = 1;
                next;
            }
            
        }
        if (!defined $uni) {$uni = $$ref[0]}
    }

    if (!defined $uni) {$uni = $result}
    $getdiner->execute($uni);
    #my $ref = $getdiner->fetchrow_arrayref;
    #if (!defined $ref) {
    my $ref;
    unless ($ref = $getdiner->fetchrow_arrayref) {
        $message = "\\Zb\\Zr\\Z1ID $uni not found.\\Zn\n\nPlease enter a UNI or ID card number:";
        $beep = 1;
        next;
    }
    $uni = $$ref[0];
    $name = $$ref[1];
    $mealplan = $$ref[2];
    $affil = $$ref[3];

    $getmealcount->execute($uni);
    my $count = ($getmealcount->fetchrow_array())[0];
    my $remaining = $mealplan - $count;

    if ($remaining < 1) {
        $message = "\\Zb\\Zr\\Z1You are out of meals!\nName: $name ($uni / $affil)\nMealplan: $mealplan\\Zn\n\nPlease enter a UNI or ID card number:";
        $beep = 1;
        next;
    }

    $todaymealcount->execute($uni);
    my $mealcount = ($todaymealcount->fetchrow_array())[0];
    my $beep = 0;
    $message = "Hello $name ($uni / $affil).";

    $prevcheckin->execute($uni);
    my $lastcheckin = ($prevcheckin->fetchrow_array())[0];
    if (defined $lastcheckin) {
        $message .= "\nYour last check-in was $lastcheckin."
    } else {
        $message .= "\nThis is your first check-in."
    }
    $message .= "\nYou have $remaining of $mealplan meals remaining.";

    if ($mealcount > 0) {$message .= "\n\\Zb\\Zr\\Z1You have already checked in today.\\Zn"; $beep = 1}

    $message .= "\nOK to check in?";
    if ($dialog->yesno( text => $message, beepbefore => $beep)) {
        $addmealcheckin->execute($uni);
        $getmealcount->execute($uni);
        $count = ($getmealcount->fetchrow_array())[0];
        $remaining = $mealplan - $count;
        $message = "Checked in $name ($uni).\nYou have $remaining of $mealplan meals remaining.\n\nPlease enter a UNI or ID card number:"
    } else {
        $message = "\\Zb\\Zr\\Z1$name ($uni) NOT checked in.\\Zn\n\nPlease enter a UNI or ID card number:"
    }
    $beep = 0;
    #$result = $dialog->inputbox( text => $message);
}

print "\nMaintaining database, please wait....\n";
$db->do("VACUUM");
print "Done."

