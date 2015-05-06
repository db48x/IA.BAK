#!/bin/env perl

# Q: what's this?
# A: i started rewriting iabak.sh in perl because bash/bash-utils are not portable enough (coreutils vs bsdutils)
#
# Q: what's the state of this subproject?
# A: there are still broken, untested and missing parts; not even alpha - this file is under heavy development!
#
# Q: what's missing?
# A: proper OSX support in installgitannex; periodicsync; cronjob and some other parts
#
# Q: i'm still not satisfied
# A: ask protodev on #internetarchive.bak EFnet


use warnings;
use strict;
use diagnostics;
use Data::Dumper;

use File::Glob qw(:globally :nocase);
use File::Copy;
use Fcntl qw(:flock);
use LWP::Simple;
use Archive::Extract;
use Cwd;
use File::Basename;
use List::Util qw (shuffle first);
use CGI;

# get("http://www.google.com") || die "Check your internet connection \n";
$|=1;


$ENV{'PATH'} = getcwd() . ($^O =~/linux/ ? "/git-annex.linux:" : "/git-annex.osx:"). $ENV{'PATH'};
my $NEED_PRERELEASE=0;
my $NUMCOPIES=4;

system('git pull origin || true');
my @curShardDirs = sharddir();
if( ~~ @curShardDirs != 0){
	unless(-e 'iabak-cronjob.log' ){
		print <<EOF
		
** Reminder: You should set up a cron job to run iabak-cronjob periodically!
             (See README.md for details)
             
EOF
	}
	
    &installgitannex;
    foreach(@curShardDirs){
        chdir($_);
        unless(-d ".empty"){
            mkdir ".empty";
        }
        system("git annex fsck --fast .empty --quiet >/dev/null 2>/dev/null; git annex sync");
        chdir("..");
    }
    for(@curShardDirs){
        handleshard($_);
    }
    
    unless( -e "NOMORE"){
        while(stillhavespace()){
            my $newShard= randnew();
            unless(length $newShard == 0){
                print "\nLooks like you still have free disk space, so I will continue to fill it up!\n(ctrl-c and touch NOMORE to prevent this behavior..)\n\n";
                checkoutshard($newShard);
                handleshard($newShard);
             }else{
                print "\nLooks like we ran out of shards for you to download before you ran out of diskspace. Please try again later!\n";
                exit 0;
            }
        }
        print "\nFilled up available disk space, so stopping here!\n";
    }
} else{
    my $localdir = randomnew();
     if(length $localdir ==0){
        print "No new shrads are currently available. Please try again later!\n";
        exit 1;
     }
     print "Looks like this is a new IA backup. I'm going to put it in\n";
     print getcwd() . "/$localdir\n";
     print "This will use some disk space :) \n";
     print "Press enter to confirm or ctrl-C to cancel:";
     print ~~<>;
     
     installgitannex();
     checkoutshard($localdir);
     chdir $localdir;
     setup();
     download(); 

}


##############################
##### and now some subs ######
##############################

sub changeEmail{
    promptEmail();
    open(FILE, "<", ".registrationemail");
    my $registrationemail = <FILE>;
    close FILE;
    for(glob("shard*")){
        if ( -d $_){
            print "Updating $_\n";
            chdir($_);
            my $uuid = `git config annex.uuid`;
            chdir("..");
            register($_, $uuid, $registrationemail);
        }
    }
    print "\nYour email address should be updated now.\n";
}

sub promptEmail{

    print "\nTo register to participate in the IA.BAK project, please\nenter a contact email address.\n\nWe will keep this email private, and only use it to contact\nyou if there is a problem with your portion of the Internet Archive backup.\n\nIt's important we have a way to get in touch with you,so that this backup can be as reliable as possible!\n\n";


    my $e1="e"; 
    my $e2="error";
    until($e1 eq $e2){
        print "\nemail adress> ";
        $e1 = ~~<>;
        print "you typed $e1\n";
        unless($e1 =~ /.+@.+?\.+/){
            print "That does not look like an email address. Try again..\n";
            next;
        }
        if(index(" ", $e1) != -1){
            print "Please enter a bare email\@example.com adress. It cannot contain any spaces\n";
            next;
        }
        print "re-enter email address to verify> ";
        $e2 = <STDIN>;
        if($e1 eq $e2){
            open(FILE, ">", ".registrationemail");
            print FILE "$e1";
            close FILE;
        }else{
            print "Emails don't match! Try again..\n";
        }
    }
    
}

sub checkoutshard{
    my $shard = shift;
    # print "shard: $shard\n";
    if(-d $shard){
        print "$shard already checked out";
        return;
    }
    
    my $top = getcwd();
    my $prevshard = ((<shard*>)[0]);
    
    unless( -e ".registrationemail"){
        changeEmail();
    }
    open(REG, "<", ".registrationemail");
    my $registrationemail = <REG>;
    close REG;

    open(REP, "<", "repolist");
    my $l = (grep /$shard/, <REP>)[0];
    close REP;
    
    unless(length $l){
        print "Shard not found in repolist";
        return;
    }
    print "\n\n$l\n";
    (my $localdir, my $repourl, my $status) = split " ", $l;
    system("git init $localdir");
    chdir($localdir);
    my $username = $ENV{USER};
    system("git config user.name $username ; git config user.email $username\@iabak ; git config gc.auto 0 ; git annex init");
    my $uuid=`git config annex.uuid`;
    chdir("..");
    checkssh($repourl, $uuid, $registrationemail);
    chdir($localdir);
    copy "../id_rsa", ".git/annex/id_rsa";
    copy "../id_rsa.pub", ".git/annex/id_rsa.pub";
    system("git remote add origin $repourl ; git config remove.origin.annex-ssh-options \"-i .git/annex/id_rsa\" ; git annex sync");
    chdir($top);
    unless(length $prevshard == 0){
        for(qw (annex.diskreserve annex.web-options)){
            chdir($prevshard);
            my $val = `git config $_`;
            unless(length $val ==0){
                chdir($localdir);
                system("git config $_ $val");
                chdir($top);
            }
        }
    }
    print "Checked out $localdir for $shard (from $repourl). Current status: $status\n";
}

sub checkssh{
    my $repourl = shift; # f.e SHARD3@iabak.archiveteam.org:shard3
    my $uuid = shift;  # generated id
    my $registrationemail = shift;
    unless (-e "id_rsa"){
        system("ssh-keygen -q -P \"\" -t rsa -f ./id_rsa");
    }
    $repourl =~ /^(.*?):(.*)$/;
    my $user = $1;
    my $dir = $2;
    print "Checking ssh to server at $repourl...\n";
    unless(`ssh -i id_rsa -o BatchMode=yes -o StrictHostKeyChecking=no "$user" git-annex-shell -c configlist $dir`){
        print "Seem you're not set up yet for access to $repourl yet. Let's fix that..\n";
# TODO        
        my @cmd;
        register($dir, $uuid, $registrationemail);
        sleep 1;  #replace with 1
        get("http://iabak.archiveteam.org/cgi-bin/pushme.cgi");
        checkssh($repourl, $uuid);
    }
}

sub randomnew{
    open(REPO, "<", "repolist");
    my @repos = <REPO>;
    close REPO;
    my @active = grep {/active$/} @repos;
    @active = (@active) ? @active : grep {/reserve$/} @repos ;
    my @existRepos;
    for(@active){
        m/(.*?) /;
    	push @existRepos, $1 unless -d $1;
    }
    return ((split " ", $existRepos[rand @existRepos])[0]);   
}


sub handleshard{
    my $shard = shift;
    print "\n========= $shard =========\n\n";
    open (my $REP, "<", "repolist") || die "could not open repolist\n";
    my @repos = <$REP>;
    my ($matched) = grep /^$shard/, @repos;
    $matched =~ /(\w+)$/;
    if($1=~"active"){
        print "active\n";
        download();
    }elsif($1=~"reserve"){
        print "reserve\n";
        download();
    }elsif($1=~"maint"){
        print "maint\n";
        maint();
    }elsif($1=~"restore"){
        print "restore\n";
        print "TODO: restore/upload\n";
    }else{
        print "Unknown state $1\n";
        exit 1;
    }
    close $REP;
}


sub download{
    system("git annex sync");
    # periodicsync &;
    print "
Here goes! Downloading from Internet Archive.
(This can be safely interrupted at any time with Ctrl-C)
(Also, you can safely run more than one of these at a time, to use more brandwidth!)

";
    if(rundownloaddirs()){
        print "\nWow! I'm done downloading this shard of the IA!\n";
    }else{
        print "\nDownload finished, but the backup of this shard is not fully complete.\nSome files may have failed to download, or all allocated disk space is in use.\n";
    }
}

sub rundownloaddirs{
    unless(-e "../NOSHUF"){
        print "(Oh good, you have shuf(1)! Randomizing order.. Will take a couple minutes..)";
        my @files = (split ' ', `git annex find --print0 --not --copies $NUMCOPIES `);
        my %dirs;
        unless(~~ @files == 0){
            %dirs = map { dirname($_) => 1 } @files;
            foreach(shuffle(keys %dirs)){
                system("git -c annex.alwayscommit=false annex get ". $_ );
            }
        }
    }
}


sub sharddir{
    my @shards;
    foreach (<shard*>) {
        push (@shards, "$_") if(-d $_);
    }
    # sorts takes a method for comparing $a and $b - ctime is compared and youngest directory comes first
    return (sort { ((stat($a))[10]) > ((stat($b))[10]) } @shards);
}


sub installgitannex{
    my $annexName = "git-annex-standalone-i386.tar.gz";
    if($^O =~ /linux/){
        # good one
        if(-d "git-annex.linux"){
            rmdir "git-annex.linux" if(&checkupdate("linux", "https://downloads.kitenet.net/git-annex/linux/current/git-annex-standalone-i386.tar.gz.info"));
            if( -e "git-annex.linux/.prerelease" && $NEED_PRERELEASE==1){
                rmdir "git-annex.linux";
            }
        }
        
        unless(-d "git-annex.linux"){
            print "Installing a recent version of git-annex ...\n";
            unlink $annexName if (-e $annexName);
            if($NEED_PRERELEASE == 1){
                getstore("https://downloads.kitenet.net/git-annex/autobuild/i386/git-annex-standalone-i386.tar.gz", "git-annex-standalone-i386.tar.gz");
            }else{
                getstore("https://downloads.kitenet.net/git-annex/linux/current/git-annex-standalone-i386.tar.gz", "git-annex-standalone-i386.tar.gz");
            }
            my $ae = Archive::Extract->new( archive => $annexName);
            my $ok = $ae->extract;
            unlink $annexName;
            if($NEED_PRERELEASE){
                fakeTouch("git-annex.linux/.prerelease");
            }
            unlink $annexName;
            print "Installed in ". getcwd() . "/git-annex.linux\n\n";
        }
    }else{
        # i'm fighting myself to support something like a bsd-fork
        # not even providing proper coreutils - that's why i'm writing everything in perl
        # ok, i should stop writing comments when i'm drunk
        if(-d "git-annex.osx"){
            unlink "git-annex.dmg";
            if($NEED_PRERELEASE == 1){
                getstore("https://downloads.kitenet.net/git-annex/autobuild/x86_64-apple-yosemite/git-annex.dmg", "git-annex.dmg");
            }else{
                getstore("https://downloads.kitenet.net/git-annex/OSX/current/10.10_Yosemite/git-annex.dmg", "git-annex.dmg");
            }
            mkdir "git-annex.osx.mnt";
            system("hdiutil attach git-annex.dmg -mountpoint git-annex.osx.mnt");
            copy("git-annex.osx.mnt/git-annex.app/Contents/MacOS/", "git-annex.osx");
            system("hdiutil eject git-annex.osx.mnt");
            if($NEED_PRERELEASE == 1){
                fakeTouch("git-annex.linux/.prerelease");
            }
            unlink "git-annex.dmg";
            rmdir "git-annex.osx.mnt";
            print "Installed in ". getcwd() . "/git-annex.linux\n\n"; 
        }
    }
}


sub checkupdate{
    my($OS, $URL) = @_;
    my ($installedVersion, $availVersion);
    if($OS =~ /linux/ ){
        `./git-annex.linux/git-annex version --raw 2>/dev/null` =~ /git-annex version: (\d\.\d{8})/;
        $installedVersion = $1;
        get("https://downloads.kitenet.net/git-annex/linux/current/git-annex-standalone-i386.tar.gz.info") =~/.*distributionVersion = "(\d\.\d{8})".*/;
        $availVersion = $1;
    }else{
        $installedVersion = `./git-annex.osx/git-annex`;
        get("https://downloads.kitenet.net/git-annex/OSX/current/10.10_Yosemite/git-annex.dmg.info") =~/.*distributionVersion = "(\d\.\d{8})".*/;
        $availVersion = $1;
    }
    # f.e 5.20150420 (decimal)
    return $installedVersion < $availVersion;
}


sub fakeTouch {
    open(PRE, ">", shift);
    print PRE "";
    close PRE;
}

sub stillhavespace {
    return 1;
}

sub register {
    my ($shard, $uuid, $email, $pubkey) = @_;
    unless ($pubkey) {
        open(PUB, "<", "id_rsa.pub");
        $pubkey = <PUB>;
        close PUB;
    }
    chomp $pubkey;
    $pubkey=~s/\+/_/g;

    my $q=CGI->new;
    $q->param("shard", uc($shard));
    $q->param("uuid", $uuid);
    $q->param("email", $email);
    $q->param("pubkey", $pubkey);
    my $url=$q->self_url;
    $url=~s!^http://localhost!http://iabak.archiveteam.org/cgi-bin/register.cgi!;
    my $result = get($url);
    # TODO: check the restult to make sure that the registration succeeded
}
