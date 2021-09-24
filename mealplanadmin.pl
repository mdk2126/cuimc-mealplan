#! /usr/bin/perl

my $version = "0.1.3";

# Update to 0.1.1 -- SQLite converts timestamps to UTC.  Adjust $dailyreport query to allow for this.
# Update to 0.1.2 -- Forced mealplan.pl to save timestamps in localtime.  Rolling back most 0.1.1 fixes.
# Update to 0.1.3 -- Add ability to load card numbers; fix problem with upper-case UNIs.

use strict;
use warnings;
use UI::Dialog::Backend::CDialog;
use DBI;
use Cwd;
use Text::CSV;

use open ':std', ':encoding(utf8)';

{ my $ofh = select STDOUT;
    $| = 1;
    select $ofh;
}

my $db = DBI->connect("dbi:SQLite:dbname=Database/mealplan.sqlite") or die $DBI::errstr;
$db->{RaiseError} = 1;
$db->{sqlite_unicode} = 1; 
$db->{AutoCommit} = 1;

my $getalldiners = $db->prepare("SELECT Name, UNI from diners ORDER BY Name");
my $getdiner = $db->prepare("SELECT UNI, Name, MealPlan, Affil from diners WHERE UNI COLLATE NOCASE = ?");
my $adddiner = $db->prepare("INSERT INTO diners (UNI, Name, MealPlan, Affil) VALUES (?,?,?,?)");
my $updatediner = $db->prepare("UPDATE diners SET Name = ?, MealPlan = ?, Affil = ? WHERE UNI COLLATE NOCASE = ?");
my $summaryreport = $db->prepare("SELECT Name, diners.UNI, Affil, MealPlan, COUNT(Timestamp) FROM diners LEFT JOIN checkin on diners.UNI = checkin.UNI GROUP BY diners.UNI ORDER BY Name");
my $meallog = $db->prepare("SELECT Name, checkin.UNI, MealPlan, Affil, Timestamp FROM diners INNER JOIN checkin on diners.UNI = checkin.UNI ORDER BY Timestamp");
# Corrected below for 0.1.2 -- my $dailyreport = $db->prepare("SELECT Name, checkin.UNI, MealPlan, Affil, datetime(Timestamp, 'localtime'), COUNT(Timestamp) FROM diners INNER JOIN checkin on diners.UNI = checkin.UNI WHERE Timestamp > DATETIME(?, 'utc') AND Timestamp < DATETIME(?, 'utc') GROUP BY checkin.UNI ORDER BY Name");
my $dailyreport = $db->prepare("SELECT Name, checkin.UNI, MealPlan, Affil, Timestamp, COUNT(Timestamp) FROM diners INNER JOIN checkin on diners.UNI = checkin.UNI WHERE Timestamp > DATETIME(?) AND Timestamp < DATETIME(?) GROUP BY checkin.UNI ORDER BY Name");
my $dailycount = $db->prepare("SELECT COUNT(Timestamp) FROM checkin WHERE Timestamp LIKE ? || '%'");
my $getmealcount = $db->prepare("SELECT COUNT(*) FROM checkin WHERE UNI COLLATE NOCASE = ?");
my $getuserlog = $db->prepare("SELECT Timestamp FROM checkin WHERE UNI = ?");
my $loaddiner = $db->prepare("INSERT OR REPLACE INTO diners (UNI, Name, MealPlan, Affil) VALUES (?,?,?,?)");
my $getids = $db->prepare("SELECT ID, UNI FROM ids WHERE UNI COLLATE NOCASE = ?");
my $getidmap = $db->prepare("SELECT Name, ids.UNI, Affil, ID, MealPlan FROM ids INNER JOIN diners ON ids.UNI = diners.UNI WHERE ids.UNI LIKE ? ORDER BY Name");
my $addcardno = $db->prepare("INSERT INTO ids (id, UNI) VALUES(?,?)");
my $getunifromid = $db->prepare("SELECT Name, ids.UNI, Affil, ID, MealPlan FROM ids LEFT JOIN diners ON ids.UNI = diners.UNI WHERE ids.ID = ?");
my $deleteid = $db->prepare("DELETE FROM ids WHERE ID = ?");

# Subroutine declarations #
sub load_diners;
sub edit_diners;
sub id_map;
sub reports;
sub db_maint;
sub get_timestamp;

my $dialog = new UI::Dialog::Backend::CDialog (backtitle => "CUIMC MealPlan Admin $version");

my $result = 1;

while(1) {

    $result = $dialog->menu( height => 12,
                             title => 'Main Menu',
                             text => 'Please select an option:',
                             list => ['LOAD_DINERS', 'Load Diners from File',
                                      'EDIT_DINERS', 'View, Edit, and Add Diners',
                                      'ID_LINK', 'View, Add, and Delete ID - UNI Links',
                                      'REPORTS', 'Run Reports',
                                      'DB_MAINT', 'Database Maintenance']);

    #print "User selected $result.\n";
    #<STDIN>;
    if ($result eq 'LOAD_DINERS') {
        load_diners;
        next;
    } elsif ($result eq 'EDIT_DINERS') {
        edit_diners;
        next;
    } elsif ($result eq 'ID_LINK') {
        id_map;
        next;
    } elsif ($result eq 'REPORTS') {
        reports;
        next;
    } elsif ($result eq 'DB_MAINT') {
        db_maint;
        next;
    } elsif ($result eq 0) {
        last;
    } else {
        die "Unknown menu option: $result (A)"
    }
}

sub load_diners {
    my $result = $dialog->msgbox( title=>"Load Diners Instructions",
                                  height => 20,
                                  text => q#The load file is a CSV file located in \\Mealplan\\Load.  The first five columns of the Load file must be:
    
    A - Name
    B - UNI
    C - Affiliation
    D - Number of meals
    E - Card Number (optional)
    
Any additional columns are ignored.  

The top line MAY be a header line, with the word "UNI" in the UNI column.  Any line where the UNI is blank or does not contain numbers will be ignored.

If a UNI already exists in the database, it will be updated.

The card number is optional.  Card numbers must be exactly 9 numeric characters.  Anything else in this column will be ignored.

To export from Microsoft Excel, save the file as type "CSV (Comma delimited)(*.csv)" to the correct directory.  The extension must be csv.  Do not use spaces in the file name.

(Note: As of Excel 2013, CSV files are encoded Windows-1252.  If Microsoft moves to UTF-8, find this text in mealplanadmin.pl and modify as indicated)#);
    ## Encodings for reading CSV files.  Comment out the line below and uncomment the following to change the encoding to UTF-8.
    my $encoding = "Windows-1252";
    #my $encoding = "UTF-8"; #Alternative if Excel changes default encoding for CSV files.
    if ($result == 0) {return undef}
    my $filespec = cwd . "/Load/*.csv";
    my $loadfile;
    my @files = glob qq("${filespec}");
    if (!defined $files[0]) {
        $dialog->msgbox (title => "No Files", text => "No suitable files found in the Load directory."); 
        return undef;
    } elsif (!defined $files[1]) {
        $loadfile = $files[0]
    } else {
        my @temp;
        my $counter = 1;
        foreach my $temp (sort @files) {
            my $file = $temp;
            $file = (split /\//, $file)[-1];
            push @temp, $counter, [$file, 0];
            $counter++;
        }
        my $temp = $dialog->radiolist(title => "Select a File to Load",
                                       text => "Select a file:",
                                       list => \@temp,
                                       height => 20,
                                       listheight => 15);
        if ($temp eq 0 or length $temp < 1) {return undef}
        $loadfile = $files[$temp-1];
    }
    my $shortfile = (split /\//, $loadfile)[-1];
    my $message = "Load file: $shortfile\n\n";
    open my $fh, "<:encoding($encoding)", $loadfile;
    my $csv = Text::CSV->new ({auto_diag => 2}) or die "Cannot use CSV: " . Text::CSV->error_diag();
    my $temp = $csv->getline($fh);
    if (!defined $temp) {$dialog->msgbox(title=>"Error Reading File",text=>"Error reading input file: $loadfile"); return undef}
    while (!defined $$temp[1] or length $$temp[1] < 2) {
        $temp = $csv->getline($fh);
        if (!defined $temp) {$dialog->msgbox(title=>"Error Reading File",text=>"Error reading input file: $loadfile"); return undef}
    }
    my $counter = 1;
    $message .= "Sample data (Please ignore the . characters):\n\n";
    my $line = sprintf('  %-18.18s | %-7.7s | %-7.7s | %-4.4s | %-9.9s', "Name", "UNI", "Affil", "Plan", "Card No");
    $line =~ s/\s/\./g;
    $line =~ s/^\.\./  /;
    $line =~ s/\.\|\./ \| /g;
    $message .= $line . "\n";
    while ($temp = $csv->getline($fh)) {
        if (!defined $$temp[1] or length $$temp[1] < 2) {next}
		if (!defined $$temp[4] or $$temp[4] !~ /\d{9}/) {$$temp[4] = " "}
        my $line = sprintf("  %-18.18s | %-7.7s | %-7.7s | %4d | %-9.9s", $$temp[0], $$temp[1], $$temp[2], $$temp[3], $$temp[4]);
        $line =~ s/\s/\./g;
        $line =~ s/^\.\./  /;
        $line =~ s/\.\|\./ \| /g;
        $message .= $line . "\n";
        $counter++;
        if ($counter > 8) {last}
    }
    close $fh;
    $message .= qq#\nSelect "Yes" to continue, "No" to abort.#;
    #print $message;
    #<STDIN>;
    unless ($dialog->yesno(title => "Confirm Load", text => $message, height => 20, 'no-collapse' => 1)) {return undef}
    open $fh, "<:encoding($encoding)", $loadfile;
    my $lines = 0;
    $counter = 0;
    $db->begin_work;
    $dialog->infobox(title => "Load Progress", text => "Please wait, loading diners....");
    while ($temp = $csv->getline($fh)) {
        $lines++;
        if (!defined $$temp[1] or length $$temp[1] < 2 or $$temp[1] !~ /\d/) {next}
        $$temp[1] = lc $$temp[1];
        $loaddiner->execute($$temp[1], $$temp[0], $$temp[3], $$temp[2]);
		if (defined $$temp[4] && $$temp[4] =~ /\d{9}/) {
			$addcardno->execute($$temp[4], $$temp[1]);
		}
        $counter++;
        if ($counter % 50 == 0) {$dialog->infobox(title => "Load Progress", text => "Please wait, loading diners....\n\n$counter diners loaded.")};
    }
    $db->commit;
    $dialog->infobox(title => "Load Progress", text => "Please wait, maintaining database....");
    $db->do("VACUUM");
    $dialog->msgbox(title=>"Load Complete", text=>"Load complete.\n\n$lines lines read from file, $counter diners loaded or updated.");
    return 1;
}

sub edit_diners {
    while (1) {
        my $result;
        my $uni;
        my $name;
        my $mealplan;
        my $affil;
        my $new = 0;
        $result = $dialog->menu( title => "View, Edit, and Add Diners Menu",
                                 text => "Please select an option:",
                                 list => ['VIEW_UNI', 'View by UNI',
                                          'VIEW_LIST', 'View from List',
                                          'EDIT_UNI', 'Edit/Add by UNI',
                                          'EDIT_LIST', 'Edit from List'],
                                 height => 12);
        if ($result eq 'VIEW_UNI' or $result eq 'EDIT_UNI') {
            $uni = $dialog->inputbox( title => "Lookup UNI", text => "Please enter a UNI:" );
            if ($uni eq 0) {next}
        } elsif ($result eq 'VIEW_LIST' or $result eq 'EDIT_LIST') {
            $getalldiners->execute();
            my @temp;
            my @options;
            while (@temp = $getalldiners->fetchrow_array) {
                push @options, ($temp[1],["$temp[0]", 0]);
            }
            if ($getalldiners->rows == 0) {$dialog->msgbox(title => "Unexpected Error", text => "No Diners in Database."); next;}
            $uni = $dialog->radiolist( title => "Select from List", 
                                       text => "Select a Diner:",
                                       list => \@options,
                                       height => "20",
                                       listheight => 15);
            if (length $uni < 2 or $uni eq 0) {next}
        } elsif ($result eq 0) {
            return undef;
        } else {
            die "Unknown menu option: $result (B)"
        }
        #print "$uni\n";
        #<STDIN>;
        $getdiner->execute($uni);
        my $ref = $getdiner->fetchrow_arrayref;
        if (!defined $ref) {
            if ($result eq 'VIEW_UNI' or $result eq 'VIEW_LIST') {$dialog->msgbox( title => 'UNI not found', text => "UNI $uni not found in database."); next}
            if($dialog->yesno( title => "Confirm New Diner", text => "\\Zb\\Zr\\Z1UNI $uni is not in the database.\\Zn\n\nAdd new diner?", beepbefore => "1")) {
                $name = "";
                $mealplan = "";
                $affil = "";
                $new = 1;
            } else {
                next;
            }
        } else {
            $name = $$ref[1];
            $mealplan = $$ref[2];
            $affil = $$ref[3];
        }
        if ($result eq 'VIEW_UNI' or $result eq 'VIEW_LIST') {
            $getmealcount->execute($uni);
            my $count = ($getmealcount->fetchrow_array())[0];
            my $message = "Diner: $name ($uni / $affil)\n$count meals of $mealplan used.\n\nID Cards linked with this diner:\n";
            my @temp;
            $getids->execute($uni);
            while (@temp = $getids->fetchrow_array) {
                $message .= "$temp[0]\n";
            }
            if ($getids-> rows == 0) {$message .= "None\n"}
            $message .= "\nCheckin Dates (PgUp/PgDn to Scroll):\n";
            $getuserlog->execute($uni);
            while (@temp = $getuserlog->fetchrow_array) {
                $message .= "$temp[0]\n";
            }
            if ($getuserlog-> rows == 0) {$message .= "None\n"}
            $dialog->msgbox( title => 'View Diner',
                             text => $message,
                             height => 20);
            next;
        }       
        my @temp = $dialog->form( title => "Edit Diner",
                                  text => "Make any changes and press OK to save, Cancel to abandon.",
                                  list => [[ 'UNI', 1, 1 ], [ $uni, 1, 13, 0, 0],
                                           [ 'Name (L, F)', 2, 1], [$name, 2, 13, 40, 100],
                                           [ '# Meals', 3, 1], [$mealplan, 3, 13, 40, 100], 
                                           [ 'Affiliation', 4, 1], [$affil, 4, 13, 40, 100]],
                                  height => 12);
        if ($temp[0] eq 0) {next}
        #print join(" | ", @temp);
        #<STDIN>;
        my $message;
        if ($new == 1) {
			$uni = lc($uni);
            $adddiner->execute($uni, $temp[0], $temp[1], $temp[2]);
            $message = "Diner added!\n";
        } else {
            $updatediner->execute($temp[0], $temp[1], $temp[2], $uni);
            $message = "Diner updated!\n";
        }
        $getdiner->execute($uni);
        $ref = $getdiner->fetchrow_arrayref;
        if (!defined $ref) {die "Unknown database error (C)."}
        $name = $$ref[1];
        $mealplan = $$ref[2];
        $affil = $$ref[3];
        $message .= "$name ($uni / $affil)\n$mealplan meals per semester.";
        $dialog->msgbox( title => "Confirmation", text => $message );
    }
}

sub id_map {
    while (1) {
        my $result = $dialog->menu( title => 'View, Add, and Delete ID - UNI Link',
                                    text => 'Please select an option:',
                                    list => ['LOOKUP_ID', 'Look Up a Single ID Card Number',
                                             'VIEW_LINK', 'View all ID - UNI Links',
                                             'ADD_LINK_UNI', 'Add an ID - UNI Link by UNI',
                                             'ADD_LINK_LIST', 'Add an ID - UNI Link from a List',
                                             'DELETE_LINK', 'Delete an ID - UNI Link'],
                                     height => 12);
        if ($result eq 'LOOKUP_ID') {
            unless($result = $dialog->inputbox( title => "Enter ID Card Number", text => "Please enter an ID Card number:" )) {next}
            unless ($result =~ /\d{9}/ && $result !~ /\d{10}/) {$dialog->msgbox ( title => 'Invalid ID Card Number', text => "\\Zr\\Z1$result is not a valid ID Card number.\\Zn\n\nID Cards numbers must be 9 digit numbers.", beepbefore => 1); next} 
            $getunifromid->execute($result);
            if (my @temp = $getunifromid->fetchrow_array) {
                $dialog->msgbox( title => "ID Card Link", text => "ID Card number $result is linked to:\n$temp[0] ($temp[1] / $temp[2])");
                next;
            } else {
                $dialog->msgbox ( title => 'ID Card Number Not Found', text => "\\Zr\\Z1The ID Card number $result could not be found the database.\\Zn", beepbefore => 1);
                next;
            }
        } elsif ($result eq 'VIEW_LINK') {
            my $message = "ID - UNI Links [Name - UNI - ID]:\n(Use PgUp/PgDn to Scroll)\n\n";
            $getidmap->execute("%");
            my @temp;
            while (@temp = $getidmap->fetchrow_array) {
                $message .= "$temp[0] - $temp[1] - $temp[3]\n";
            }
            if ($getuserlog-> rows == 0) {$message .= "None\n"}
            $dialog->msgbox( title => "ID - UNI Links", text => $message, height => 20);
            next;
        } elsif ($result eq 'ADD_LINK_UNI') {
            my @temp;
            unless (@temp = $dialog->form( title => "Add ID Card Link",
                                     text => "Input UNI and ID Card number and press OK to save, Cancel to abandon.",
                                     list => [[ 'UNI', 1, 1 ], ['', 1, 13, 40, 40],
                                              [ 'ID Card No.', 2, 1], ['', 2, 13, 40, 100]],
                                     height => 10,
                                     formheight => 2)) {next}
            if ($temp[0] eq '0') {next}
            unless (defined $temp[1] && $temp[1] =~ /\d{9}/ && $temp[1] !~ /\d{10}/) {$dialog->msgbox ( title => 'Invalid ID Card Number', text => "\\Zr\\Z1$temp[1] is not a valid ID Card number.\\Zn\n\nID Cards numbers must be 9 digit numbers.", beepbefore => 1); next} 
            unless (defined $temp[0] && $temp[0] =~ /^\w{2,3}\d{1,4}/) {$dialog->msgbox ( title => 'Invalid UNI', text => "\\Zr\\Z1$temp[0] is not a valid UNI number.\\Zn.", beepbefore => 1); next} 
            my $uni = $temp[0];
            my $id = $temp[1];
            chomp $uni;
            $uni =~ s/\s+//g;
            chomp $id;
            $id =~ s/\s+//g;
            $getdiner->execute($uni);
            unless (@temp = $getdiner->fetchrow_array) {$dialog->msgbox( title => 'UNI not found', text => "UNI $uni not found in the diner database."); next};
            unless ($dialog->yesno( text=> "Name: $temp[1] ($uni / $temp[3])\nCard: $id\n\nOK to link $id with $temp[1]?")) {next}
            $addcardno->{PrintError} = 0;
            $addcardno->{RaiseError} = 0;
            my $rv = $addcardno->execute($id, $uni);
            $addcardno->{RaiseError} = 1;
            $addcardno->{PrintError} = 1;
            if ($rv) {
                $dialog->msgbox ( title => 'ID Card Number Added', text => "ID Card number $id added for $uni."); 
                next;
            } else {
                $dialog->msgbox ( title => 'ID Card Number NOT Added', text => "\\Zr\\Z1The ID Card number $result could not be added to the database.\\Zn  The database returned the following error:\n\n" . $addcardno->errstr . " (" . $addcardno->err . ")", beepbefore => 1);
                next;
            }
        } elsif ($result eq 'ADD_LINK_LIST') {
            $getalldiners->execute();
            my @temp;
            my @options;
            while (@temp = $getalldiners->fetchrow_array) {
                push @options, ($temp[1],["$temp[0]", 0]);
            }
            if ($getalldiners->rows == 0) {$dialog->msgbox(title => "Unexpected Error", text => "No Diners in Database."); next;}
            my $uni = $dialog->radiolist( title => "Select from List", 
                                       text => "Select a Diner:",
                                       list => \@options,
                                       height => "20",
                                       listheight => 15);
            if (length $uni < 2 or $uni eq 0) {next}
            $getdiner->execute($uni);
            @temp = $getdiner->fetchrow_array;
            if ($result = $dialog->inputbox( title => 'Link ID with UNI', text=> "Name: $temp[1] ($uni / $temp[3])\n\nInput ID Card number to link, or Cancel to abort:")) {
                unless ($result =~ /\d{9}/ && $result !~ /\d{10}/) {$dialog->msgbox ( title => 'Invalid ID Card Number', text => "\\Zr\\Z1$result is not a valid ID Card number.\\Zn  ID Cards numbers must be 9 digit numbers.", beepbefore => 1); next}
                $addcardno->{PrintError} = 0;
                $addcardno->{RaiseError} = 0;
                my $rv = $addcardno->execute($result, $uni);
                $addcardno->{RaiseError} = 1;
                $addcardno->{PrintError} = 1;
                if ($rv) {
                    $dialog->msgbox ( title => 'ID Card Number Added', text => "ID Card number added successfully."); 
                    next;
                } else {
                    $dialog->msgbox ( title => 'ID Card Number NOT Added', text => "\\Zr\\Z1The ID Card number $result could not be added to the database.\\Zn  The database returned the following error:\n\n" . $addcardno->errstr . " (" . $addcardno->err . ")", beepbefore => 1);
                    next;
                }
            } else {
                next;
            }
        } elsif ($result eq 'DELETE_LINK') {
            unless($result = $dialog->inputbox( title => "Enter ID Card Number", text => "Please enter an ID Card number:" )) {next}
            unless ($result =~ /\d{9}/ && $result !~ /\d{10}/) {$dialog->msgbox ( title => 'Invalid ID Card Number', text => "\\Zr\\Z1$result is not a valid ID Card number.\\Zn\n\nID Cards numbers must be 9 digit numbers.", beepbefore => 1); next} 
            $getunifromid->execute($result);
            my @temp;
            unless (@temp = $getunifromid->fetchrow_array) {
                $dialog->msgbox ( title => 'ID Card Number Not Found', text => "\\Zr\\Z1The ID Card number $result could not be found the database.\\Zn", beepbefore => 1);
                next;
            }
            my $id = $result;
            if ($result = $dialog->yesno( title => "ID Card Link", text => "ID Card number $result is linked with:\n$temp[0] ($temp[1] / $temp[2])\n\nOK to delete link?")) {
                $deleteid->execute($id);
                $dialog->msgbox( title => "ID Link Deleted", text => "ID Card $id has been removed from the database.");
                next;
            } else {
                $dialog->msgbox ( title => 'ID Link Not Deleted', text => "\\Zr\\Z1ID Card $id has not been removed from the database.\\Zn", beepbefore => 1);
                next;
            }
        } elsif ($result eq '0') {
            return undef;
        } else {
            die "Unknown menu option: $result (F)"
        }
    }
}

sub reports {
    while (1) {
        my $result = $dialog->menu( title => "Reports Menu",
                                    text => "Please select an option:",
                                    list => ["SUMMARY", "Summary Report",
                                             "TRANSACT", "Transaction Log Detail",
                                             "DAILY", "Daily Report"]);
        if ($result eq "SUMMARY") {
            unless ($dialog->yesno ( title => 'Summary Report (To-Date)',
                                     text => "The summary report includes all diners and count of meals used to date in a CSV file.  The report will be saved in Mealplan\\Report as Mealplan-Summary-YYYYMMDD-HHMMSS.csv.\n\nRun Report?",
                                     height => 12)) {next}
            $summaryreport->execute();
            my $csv = Text::CSV->new ({ eol => "\r\n",
                                        auto_diag => 2}) or die "Cannot use CSV: " . Text::CSV->error_diag();
            my @header = ("Name","UNI","Affiliation","Mealplan","Meals Used");
            my $datetime = get_timestamp;
            my $filename = cwd . '/Report/Mealplan-Summary-' . $datetime . '.csv' ;
            open my $fh, ">", $filename or die "Cannot open output file $filename: $!\n";
            $csv->print($fh, \@header);
            #print OUTFIL $header;
            my @temp;
            while(@temp = $summaryreport->fetchrow_array) {
                #my $temp = join "\t", @temp;
                #print OUTFIL $temp . "\n";
                $csv->print($fh, \@temp)
            }
            close $fh;
            #next;
        } elsif ($result eq "TRANSACT") {
            unless ($dialog->yesno ( title => 'Transaction Log Detail (To-Date)',
                                     text => "The transaction log detail includes all dining check-in timestamps and associated information in a CSV file.  The report will be saved in Mealplan\\Report as Mealplan-Transaction-Log-YYYYMMDD-HHMMSS.csv.\n\nRun Report?",
                                     height => 12)) {next}
            $meallog->execute();
            my $csv = Text::CSV->new ({ eol => "\r\n",
                                        auto_diag => 2}) or die "Cannot use CSV: " . Text::CSV->error_diag();
            my @header = (qw#Name UNI Mealplan Affiliation Timestamp#);
            my $datetime = get_timestamp;
            my $filename = cwd . '/Report/Mealplan-Transaction-Log-' . $datetime . '.csv' ;
            open my $fh, ">", $filename or die "Cannot open output file $filename: $!\n";
            $csv->print($fh, \@header);
            my @temp;
            while(@temp = $meallog->fetchrow_array) {
                $csv->print($fh, \@temp)
            }
            close $fh;
            #next;
            
        } elsif ($result eq "DAILY") {
            my @lt = localtime(time);
            my ($y,$m,$d) = ($lt[5]+1900, $lt[4]+1, $lt[3]);
            my $date = $dialog->calendar ( title => 'Daily Summary',
                                           text => "Total check-ins and list of all diners checking in on a date. Saved in Mealplan\\Report as Daily-Report-YYYYMMDD.csv.\n\nPick a date to continue:",
                                           day => $d,
                                           month => $m,
                                           year => $y,
                                          );
            if ($date eq 0) {next}
            ($d,$m,$y) = split /\//, $date;
            my $filedate = sprintf("%04d%02d%02d", $y, $m, $d);
            my $rptdate = sprintf("%04d-%02d-%02d", $y, $m, $d);
            my $rptstartdate = sprintf("%04d-%02d-%02d", $y, $m, $d) . " 00:00";
            my $rptenddate = sprintf("%04d-%02d-%02d", $y, $m, $d) . " 24:00";
            $dailyreport->execute($rptstartdate, $rptenddate);
            $dailycount->execute($rptdate);
	    #chomp $rptdate;
            my $count = ($dailycount->fetchrow_array())[0];
            my $csv = Text::CSV->new ({ eol => "\r\n",
                                        auto_diag => 2}) or die "Cannot use CSV: " . Text::CSV->error_diag();

            #Name, checkin.UNI, MealPlan, Affil, Timestamp, COUNT(Timestamp)
            my @header = (qw#Name UNI Mealplan Affiliation Timestamp#, "# Check-ins");
            my $filename = cwd . '/Report/Daily-Report-' . $filedate . '.csv' ;
            open my $fh, ">", $filename or die "Cannot open output file $filename: $!\n";
            my $today = scalar localtime();
            $csv->print($fh, ["Daily Report For:",$rptdate]);
            $csv->print($fh, ["Report Run Time:",$today]);
            $csv->print($fh, ["Total Meals:", $count]);
            $csv->print($fh, []);
            $csv->print($fh, \@header);
            my @temp;
            while(@temp = $dailyreport->fetchrow_array) {
                $csv->print($fh, \@temp)
            }
            close $fh;
            #next;
        
        } elsif ($result eq 0) {
            return undef;        
        } else {
            die "Unknown menu option: $result (E)"
        }
        $dialog->msgbox( title => "Report Complete", text => "Report complete.")
    }

}

sub db_maint {
    while (1) {
        my $result = $dialog->menu( title => "Database Maintenance Menu",
                                    text => "Please select an option:",
                                    list => ['BACKUP', 'Backup Database',
                                             'CLEAR', 'Clear Diners, Transactions, and/or Cards',
                                             'REBUILD', 'Delete and Re-Build the Database']);
        if ($result eq 'BACKUP') {
            unless ($dialog->yesno( title => "Confirm Backup", text => "Are you sure you want to backup the database?" )) {next}
            my $time = get_timestamp;
            my $backupfile = cwd . '/Backup/mealplan-database-' . $time . '.sqlite' ;
            my $printbackup = 'Backup/mealplan-database-' . $time . '.sqlite' ;
            my $tempdb = DBI->connect("dbi:SQLite:dbname=$backupfile") or die $DBI::errstr;
            $tempdb->disconnect();
            $db->sqlite_backup_to_file($backupfile);
            $dialog->msgbox( title => 'Backup Complete', text => "Backup to $printbackup complete.");
        } elsif ($result eq 'CLEAR') {
            my @temp = $dialog->checklist( title => "Select Database Tables",
                                           text => "\\Zr\\Z1This will delete ALL items from the selected tables.\\Zn\n\nIt is highly recommended that you backup the database before proceeding.\n\nSelect one or more tables:", 
                                           list => ['DINERS', [ 'Diners and Meal Plans', 0 ],
                                                    'CHECKINS', [ 'Check-In Records', 0],
                                                    'IDCARDS', [ 'ID Card - UNI Mappings', 0]],
                                           beepbefore => "1", 
                                           height => 20);
            my $diners = 0;
            my $checkins = 0;
            my $idcards = 0;
            my $message = "";
            #print join " | ", @temp;
            #<STDIN>;
            if (!defined $temp[0] or $temp[0] eq 0 or length $temp[0] < 2) {next}
            foreach my $temp (@temp) {
                if ($temp eq "DINERS") {
                    $diners = 1;
                    $message .= "    Diners and Meal Plans\n";
                } elsif ($temp eq "CHECKINS") {
                    $checkins = 1;
                    $message .= "    Check-In Records\n";
                } elsif ($temp eq "IDCARDS") {
                    $idcards = 1;
                    $message .= "    ID Card - UNI Mappings\n"
                }
            }
            my $result = $dialog->inputbox( title => "Confirm Clear Database", 
                                            text => "\\Zr\\Z1This will delete the following:\\Zn\n$message\nIt is highly recommended that you backup the database before proceeding.\n\nType the following in the box below and select OK to continue: yEs!", 
                                            beepbefore => "1", 
                                            height => 20);
            if ($result eq "yEs!") {
                if ($diners == 1) {$db->do("DELETE FROM diners")}
                if ($checkins == 1) {$db->do("DELETE FROM checkin")}
                if ($idcards == 1) {$db->do("DELETE FROM ids")}
                $dialog->infobox(title => "Database Cleared", text => "Please wait, maintaining database....");
                $db->do("VACUUM");
                $dialog->msgbox( title => "Database Cleared", text => "The following have been deleted:\n$message");
            } else {
                $dialog->msgbox( title => "Database NOT Cleared", text => "\\Zr\\Z1No Database Changes Made!\\Zn", beepbefore => "1");
            }
            
        } elsif ($result eq 'REBUILD') {
            my $result = $dialog->inputbox( title => "Confirm Re-Build Database", 
                                            text => "\\Zr\\Z1This will delete ALL data from the database and re-build it.\\Zn\n\nIt is highly recommended that you backup the database before proceeding.\n\nType the following in the box below and select OK to continue: yEs!", 
                                            beepbefore => "1", 
                                            height => 20);
            if ($result eq "yEs!") {
                $db->begin_work;
                $db->do("DROP INDEX IF EXISTS UNI");
                $db->do("DROP INDEX IF EXISTS UNID");
                $db->do("DROP INDEX IF EXISTS ID");
                $db->do("DROP TABLE IF EXISTS diners");
                $db->do("DROP TABLE IF EXISTS ids");
                $db->do("DROP TABLE IF EXISTS checkin");
                $db->do("CREATE TABLE diners (UNI unique COLLATE NOCASE, Name, MealPlan, Affil text)");
                $db->do("CREATE TABLE ids (ID unique, UNI)");
                $db->do("CREATE TABLE checkin (UNI, Timestamp default CURRENT_TIMESTAMP)");
                $db->do("CREATE INDEX UNI on checkin (UNI)");
                $db->do("CREATE INDEX ID on ids (ID)");
                $db->do("CREATE INDEX UNID on diners (UNI)");
                $db->commit;
                $db->do("VACUUM");
                $dialog->msgbox( title => "Database Re-Built", text => "The database has been re-built.");
            } else {
                $dialog->msgbox( title => "Database NOT Re-Built", text => "\\Zr\\Z1No Database Changes Made!\\Zn", beepbefore => "1");
            }
        } elsif ($result eq 0) {
            return undef;
        } else {
            die "Unknown menu option: $result (D)"
        }
    }
}

sub get_timestamp {
    my @temp = localtime(time);
    my $time = sprintf("%04d%02d%02d-%02d%02d%02d", $temp[5]+1900, $temp[4]+1, $temp[3], $temp[2], $temp[1], $temp[0]);
    return $time;
}
