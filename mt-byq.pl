#!/usr/bin/perl

# programowanie MT z bazy LMS
#
# org: http://lists.lms.org.pl/pipermail/lms/attachments/20100308/def9d726/attachment-0001.ksh 
#
# testowane z 
# RB750GL ver 6.4 i 6.20
# CCR1009-8G-1S ver 6.21.1
#
# LMS 1.10.4, oraz LMS 1.11-git DB: 2014072500
#
# system/packages > wireless on
# system/logging > error na disk
# 
# nazwa serwer DHCP (dawne pole domain) w LMS musi byc identyczna z nazwa server w MT
# nazwa interfejs w LMS musi byc identyczna z nazwa interfejsu w MT (interfejsem moze byc vlan, bridge lub fizyczny)
# aby wlaczyc autoryzacje po mac nalezy dla danego interface w MT ustawic ARP: reply-only
# by dzialal range dhcp dla nowych nalezy zaznaczyc w dhcp serwer na mt add-arp
# by dzialaly komunikaty nowykomp i blokada nalezy w mt dodac reguly firewall na forward i dstnat oraz dodac address list na range dhcp i dodac pool
# 
#
# dodatkowe pole na IP w LMS jest uwzgledniane tylko przy tworzeniu kolejek - nie w arp
# 
# Grzegorz Cichowski
# gc@lanet.waw.pl gcichowski@gmail.com
# 

use strict;
use DBI;
use Mtik;
use Config::IniFiles;
use Getopt::Long;
use Time::Local;
use POSIX qw(strftime mktime);
use vars qw($configfile $quiet $help $version $force $fakedate $mklistfile $error_msg $debug $info);

$ENV{'PATH'}='/sbin:/usr/sbin:/usr/local/sbin:/bin:/usr/bin:/usr/local/bin:/etc/rc.d/:/etc/lms-nett';

sub mask2prefix($);
sub matchip($$$);
sub dotquad2u32($);
sub u32todotquad($);
sub localtime2();
sub taryfy($$);
sub polacz_z_baza();
sub sprawdz_zmiany();

my $_version = '2.1.28a';

my %options = (
	"--debug|d"             =>     \$debug,
	"--info|i"              =>     \$info,
	"--config-file|C=s"	=>	\$configfile,
	"--mklist|l=s"		=>	\$mklistfile,
	"--quiet|q"		=>	\$quiet,
	"--help|h"		=>	\$help,
	"--version|v"		=>	\$version,
	"--force"		=>	\$force
);

Getopt::Long::config("no_ignore_case");
GetOptions(%options);

if($help) {
	print STDERR <<EOF;
mikrotik, version $_version
(C) 2001-2006 LMS Developers
(C) 2009-2010 Emers, Wojtek
(C) 2014-20xx byq

-C, --config-file=/etc/lms-nett/lms.ini	alternate config file (default: /etc/lms-nett/lms.ini);
-l, --mklist=/etc/lms-nett/mikrotik.list	mikrotik's list file (default: /etc/lms-nett/mikrotik.list);
-h, --help			print this help and exit;
-v, --version			print version info and exit;
-q, --info			show only changes;
-q, --quiet			suppress any output, except errors;
-f, --force			force reload specific mikrotik;

EOF
	exit 0;
}

if($version) {
	print STDERR <<EOF;
mikrotik, version $_version
(C) 2001-2006 LMS Developers
(C) 2009-2010 Emers, Wojtek
(C) 2013-20xx byq

EOF
	exit 0;
}

if(!$configfile) {
	$configfile = "/etc/lms-nett/lms.ini";
}

if(!$mklistfile) {
	$mklistfile = "/etc/lms-nett/mikrotik.list";
}

if($version) {
	print STDOUT "mikrotik, version $_version\n";
	print STDOUT "(C) Copyright 2001-2006 LMS Developers\n";
	print STDOUT "(C) Copyright 2009-2010 Emers\n";
	print STDOUT "(C) Copyright 2013-20xx byq\n";
	print STDOUT "Using file $configfile as config.\n";
	print STDOUT "Using file $mklistfile as mikrotik's list.\n";
}

if(! -r $configfile) {
	print STDERR "Fatal error: Unable to read configuration file $configfile, exiting.\n";
	exit 1;
}

if(! -r $mklistfile) {
	print STDERR "Fatal error: Unable to read mikrotik file $mklistfile, exiting.\n";
	exit 1;
}

my $ini = new Config::IniFiles -file => $configfile;
print @Config::IniFiles::errors;

my $dbhost = $ini->val('database', 'host') || 'localhost';
my $dbuser = $ini->val('database', 'user') || 'root';
my $dbpasswd = $ini->val('database', 'password') || '';
my $dbname = $ini->val('database', 'database') || 'lms';
my $dbtype = $ini->val('database', 'type') || 'mysql';

my $hostname;
my $mkhost;
my $mkuser;
my $mkpass;
my $mknetl;
my $dbase;
my $ipjestwsieci;
my $mask;
my $address;

my $def_down=10;	# minimalny download dla osob bez taryfy, potrzebny by dac dostep dp stron serwisowych
my $def_up=10;		# minimalny upload dla osob bez taryfy, potrzebny by dac dostep dp stron serwisowych
my $aclprefix='LMS';	# przefix dodawany do wpisów generowanych automatycznie, przydatne, by odró¿niæ od statycznych
my $tariff_mult=1;	# mno¿nik uploadu i downloadu, dobrze ustawiæ >1, by MT nie traci³ mocy CPU na zarz±dzanie pasmem, gdy u¿ytkownik osi±ga warto¶æ graniczn± taryfy

#nie znaznacza do usuniecia, oraz nie wyciaga z bazy kompow z taka nazwa
my $macs_usunac='do_pominiecia-';	# ignoruj urz±dzenia z tym prefixem w polu name, najczê¶ciej to sprzêt sieciowy, którego nie trzeba ograniczaæ
my $api_delay=0;	# czas (w sekundach) oczekiwania po zmianie/dokonaniu wpisu

my $acl_enable=0; 	# czy zarzadzac accesslista
my $queue_enable=1; 	# czy zarzadzac kolejkami
my $dhcp_enable=1;	# czy zarzadzac dhcp
my $arp_enable=1;	# czy zarzadzac arp
my $bloklista_enable=1;	# czy zarzadzac bloklista w firewallu

#domyslne ustawienia regulki interface wireless access-list
my $macs_private_algo='none';
my $macs_disabled='false';
my $macs_forwarding='true';
my $macs_authentication='true';
my $macs_client_tx_limit='0';
my $macs_ap_tx_limit='0';
my $macs_signal_range='-120..120';
my $macs_private_pre_shared_key='';
my $macs_private_key='';

#domyslne ustawienia regulki simple queue
my $simple_burst_limit= '0/0';
my $simple_burst_threshold= '0/0';
my $simple_burst_time= '0s/0s';
my $simple_disable= 'no';
my $simple_direction= 'both';
my $simple_dst_address= '0.0.0.0/0';
my $simple_limit_at= '0/0';
my $simple_interface = 'all';
my $simple_parent = 'none';
my $simple_priority = '8';
my $simple_queue = 'wireless-default/wireless-default';
my $simple_time = '12h-1d,sun,mon,tue,wed,thu,fri,sat';
my $simple_time_n = '0s-12h,sun,mon,tue,wed,thu,fri,sat';
my $simple_total_queue = 'default-small';

# nazwa listy z blokowanymi IP
my $bloklista_nazwalisty = 'blokada';

# recznie dodane wpisy ARP, ktore maja nie byc kasowane
my $arp_nottodelete = 'nie_usuwac';

my(%wireless_macs);
my(%wireless_queues);
my(%wireless_dhcp);
my(%wireless_arp);
my(%wireless_bloklista);

if ( polacz_z_baza() ) {
	open(FILE, "$mklistfile");
	my @list = <FILE>;
	close(FILE);
	foreach my $row(@list) { # wykonuj dla ka¿dego MT odczytanego z listy
		$_=$row;
		my @mkdata = split(';',$row,5);
		$mknetl = pop(@mkdata);
		$mkpass = pop(@mkdata);
		$mkuser = pop(@mkdata);
		$mkhost = pop(@mkdata);
		$hostname = pop(@mkdata);

		if(sprawdz_zmiany() or $force) {
			if(!$quiet) { print STDERR "Konieczne przeladowanie mk: $hostname, host: $mkhost, user: $mkuser, pass: *****\n"; }
			if (Mtik::login($mkhost,$mkuser,$mkpass)) {


if(!$quiet) { print STDERR "Zalogowano"; }

# odczyt aktualnych wpisow

if ($acl_enable) {
    if (!$quiet) { print STDERR "\n\nAktualnie dodane wpisy do access listy:\n---------------------------------------\n"; }
    %wireless_macs = Mtik::get_by_key('/interface/wireless/access-list/print','.id');
#    print STDERR " error: $Mtik::error_msg\n";
    if ($Mtik::error_msg eq '' ) {
		    print STDERR " acl enable\n"; 
	foreach my $id (keys (%wireless_macs)) {
		if(!$quiet) { print STDERR " ID: $id |"; }
		# zaznaczamy domy¶lnie ka¿dy wpis do usuniêcia
		$_=$wireless_macs{$id}{'comment'};
		if (/$macs_usunac/) { $wireless_macs{$id}{'LMS'} = '2'; }
		else { $wireless_macs{$id}{'LMS'} = '0'; }
	}
    }
}

if($queue_enable) {
    if(!$quiet) { print STDERR "\n\nAktualnie dodane kolejki queue simple:\n--------------------------------------\n"; }
    %wireless_queues = Mtik::get_by_key('/queue/simple/print','name');

#		print STDERR " error: $Mtik::error_msg\n";

if ($Mtik::error_msg eq '' and $queue_enable) {
#		    print STDERR " queue enable\n"; 
	foreach my $name_queues (keys (%wireless_queues)) {
		if(!$quiet) { print STDERR " Name: $name_queues |"; }
		# zaznaczamy domyslnie kazdy wpis do usuniecia
		$_=$wireless_queues{$name_queues}{'comment'};
		if (/$macs_usunac/) { $wireless_queues{$name_queues}{'LMS'} = '2'; }
		else { $wireless_queues{$name_queues}{'LMS'} = '0'; }
	}
    }
}

if(!$quiet and $dhcp_enable) { print STDERR "\n\nAktualnie dodane wpisy do serwera dhcp:\n---------------------------------------\n"; }
    %wireless_dhcp = Mtik::get_by_key('/ip/dhcp-server/lease/print','.id');

#		print STDERR " error: $Mtik::error_msg\n";

if ($Mtik::error_msg eq '' and $dhcp_enable) {
#		    print STDERR " dhcp enable\n"; 
	foreach my $id (keys (%wireless_dhcp)) {
		if(!$quiet) { 
		    print STDERR " ID: $id |"; 
		}
		# zaznaczamy domyslnie kazdy wpis do usuniecia
		$_=$wireless_dhcp{$id}{'comment'};
		if (/$macs_usunac/) { $wireless_dhcp{$id}{'LMS'} = '2'; }
		else { $wireless_dhcp{$id}{'LMS'} = '0'; }
#		print STDERR $wireless_dhcp{$id}{'LMS'};
	}
}

if(!$quiet and $arp_enable) { print STDERR "\n\nAktualnie dodane wpisy arp:\n---------------------------------------\n"; }
%wireless_arp = Mtik::get_by_key('/ip/arp/print','.id');

#		print STDERR " error: $Mtik::error_msg\n";

if ($Mtik::error_msg eq '' and $arp_enable) {
#		    print STDERR " arp enable\n"; 
	foreach my $id (keys (%wireless_arp)) {
		if(!$quiet) { 
		    print STDERR " ID: $id |"; 
		}
		# zaznaczamy domyslnie kazdy wpis do usuniecia ( 0 = usun)
		$_=$wireless_arp{$id}{'comment'};
		if (/$macs_usunac/ || /$arp_nottodelete/) { 
		    $wireless_arp{$id}{'LMS'} = '2'; 
#		    print STDERR " 2 |$wireless_arp{$id}{'comment'}"; 
		    }
		else { 
		    $wireless_arp{$id}{'LMS'} = '0'; 
#		    print STDERR " 0 |$wireless_arp{$id}{'comment'}"; 
		}
	}
}

if ($bloklista_enable) {
    if (!$quiet) { print STDERR "\n\nAktualnie dodane wpisy do bloklisty:\n---------------------------------------\n"; }
    %wireless_bloklista = Mtik::get_by_key('/ip/firewall/address-list/print','.id');
#    print STDERR " error: $Mtik::error_msg\n";
    if ($Mtik::error_msg eq '' ) {
#		    print STDERR " bloklista enable\n"; 
	foreach my $id (keys (%wireless_bloklista)) {
		if(!$quiet) { print STDERR " ID: $id |"; }
		# zaznaczamy domyslnie kazdy wpis do usuniecia
		$_=$wireless_bloklista{$id}{'list'};
		if (/$bloklista_nazwalisty/) { $wireless_bloklista{$id}{'LMS'} = '0'; }
		else { $wireless_bloklista{$id}{'LMS'} = '2'; }
#		print STDERR " u: $wireless_bloklista{$id}{'LMS'} |"; 
	}
    }
}

if(!$quiet and ( $acl_enable or $queue_enable or $dhcp_enable or $arp_enable or $bloklista_enable)) { print STDERR "\n";}
my @networks = split ' ', $mknetl;
foreach my $key (@networks) {
# pobranie sieci z bazy
	my $dbq = $dbase->prepare("SELECT id, inet_ntoa(address) AS address, mask, interface, domain  FROM networks WHERE name = UPPER('$key')");
	$dbq->execute();
	if(!$quiet and ( $acl_enable or $queue_enable or $dhcp_enable or $arp_enable ) ) { print STDERR "\nSprawdzam siec: $key\n";}
	while (my $row = $dbq->fetchrow_hashref()) {
# pobranie komputerow z bazy
		my $dbq2 = $dbase->prepare("SELECT id, name, ipaddr, ipaddr_pub, mac, ownerid, access FROM vnodes WHERE name not like '%$macs_usunac%' ORDER BY ipaddr ASC");
		$dbq2->execute();
		my $iface = $row->{'interface'}; # nazwa interfejsu na MT przechowywana jest w polu interface w konfiguracji konkretnej sieci
		my $server = $row->{'domain'}; # nazwa servera dhcp na MT przechowywana jest w polu domain w konfiguracji konkretnej sieci
		$mask = $row->{'mask'};
		$address = $row->{'address'};
		while (my $row2 = $dbq2->fetchrow_hashref()) {
			$row2->{'ipaddr'} = u32todotquad($row2->{'ipaddr'});
			$row2->{'ipaddr_pub'} = u32todotquad($row2->{'ipaddr_pub'});
			if(matchip($row2->{'ipaddr'},$row->{'address'},$row->{'mask'})) {
				my $ipaddr_;
				my $ipaddr_32;
				my $ipaddr = $row2->{'ipaddr'};
				my $ipaddr_pub = $row2->{'ipaddr_pub'};
				my $cmac = $row2->{'mac'};
				my $access = $row2->{'access'};
#                            print STDERR " ip: $ipaddr  ";
				my $ownerid = $row2->{'ownerid'};
				my $ipaddr32=$ipaddr."/32";
				my $ipaddr_pub32=$ipaddr_pub."/32";
				my $name_kolejka = $row2->{'name'};
				# budujemy opis, jesli zaczyna sie od prefixu LMS, to jest dodane przez skrypt
				my $name = $aclprefix.':uid'.$ownerid.':nid'.$row2->{'id'}.':'.$row2->{'name'};
				my $taryfa = taryfy($ownerid,$ipaddr);
				# ustawiamy domyslna predkosc, nawet jak ktos nie ma taryfy, aby wyswietlaly sie strony serwisowe
				my $down=$def_down;
				my $up=$def_up;
				my $down_n=$def_down;
				my $up_n=$def_up;
				my $currtime = strftime("%s",localtime2());
				my $dbq3 = $dbase->prepare("SELECT upceil, downceil, upceil_n, downceil_n FROM tariffs WHERE id=$taryfa");
				$dbq3->execute();

# tutaj siorbnac z bazy predkosci wynikajace z PP
				my $wyciagtaryfy2 = $dbase->prepare("SELECT mbps4ref, mbps4refup FROM assignments WHERE referrerid=$ownerid AND (datefrom <= $currtime OR datefrom = 0) AND (dateto > $currtime OR dateto = 0) AND suspended = 0");
				$wyciagtaryfy2->execute();
#
# tutaj dodac w petli sumowanie predkosci z PP
                   		my $suma4ref = 0;
            			my $suma4refup = 0;
            			my $tmpmbps4refup = 0;
            			my $tmpmbps4ref = 0;
            			my $row4refup = 0;
            			my $row4ref = 0;

                   		while (my $rowwyciagtaryfy2 = $wyciagtaryfy2->fetchrow_hashref())
                   		{
                    		    $row4refup = $rowwyciagtaryfy2->{'mbps4refup'};
                    		    $row4ref = $rowwyciagtaryfy2->{'mbps4ref'};
                    		    $tmpmbps4refup = lc($row4refup);
                    		    $tmpmbps4ref = lc($row4ref);
                    		    my $tmp4refup = $tmpmbps4refup * 1024;
                		    $suma4refup += $tmp4refup;
                       		    my $tmp4ref = $tmpmbps4ref * 1024;
                       		    $suma4ref += $tmp4ref;
                   		}
				while (my $row3 = $dbq3->fetchrow_hashref()) {


					$down = $row3->{'downceil'} * $tariff_mult;
# i dodac je do predkosci kupionej przez klienta
					$down += $suma4ref;

					$up = $row3->{'upceil'} * $tariff_mult;
					$up += $suma4refup;

					if (!$row3->{'downceil_n'}) {$down_n = $down; }
					else {
					    $down_n = $row3->{'downceil_n'} * $tariff_mult;
					    }
					if (!$row3->{'upceil_n'}) {$up_n = $up; }
					else {
					    $up_n = $row3->{'upceil_n'} * $tariff_mult;
					    $up_n += $suma4refup;
					    }
				}
				my $max_limit= $up."000/".$down."000";
				my $max_limit_n= $up_n."000/".$down_n."000";
				if (!$quiet and $acl_enable) { print STDERR "$cmac @ $iface <-> "; }
				# szukamy czy mamy juz zarejestrowany komputer na MT
				my $zarejestrowany = 0 ;

####### acl v
				if ($acl_enable) {
				    foreach my $id (keys (%wireless_macs)) {
					if ( ($wireless_macs{$id}{'mac-address'} eq $cmac ) and ( $wireless_macs{$id}{'interface'} eq $iface) ) {
						if (!$quiet) { print STDERR "acl istnieje -> "; }
						$zarejestrowany=1;
						my $poprawic_wpis=0;
						my %attrs4;
						# je¶li ju¿ dodany, to trzeba sprawdziæ wszystkie atrybuty i ewentualnie poprawiæ
						# maca i interfejsu nie sprawdzamy bo zrobili¶my to wcze¶niej
						if ( $wireless_macs{$id}{'private-algo'} ne $macs_private_algo )                     { $wireless_macs{$id}{'private-algo'}=$macs_private_algo;                      $poprawic_wpis+= 1;   $attrs4{'private-algo'}=$macs_private_algo; }
						if ( $wireless_macs{$id}{'disabled'} ne $macs_disabled )                             { $wireless_macs{$id}{'disabled'}=$macs_disabled ;                             $poprawic_wpis+= 2;   $attrs4{'disabled'}=$macs_disabled; }
						if ( $wireless_macs{$id}{'forwarding'} ne $macs_forwarding )                         { $wireless_macs{$id}{'forwarding'}=$macs_forwarding ;                         $poprawic_wpis+= 4;   $attrs4{'forwarding'}=$macs_forwarding; }
						if ( $wireless_macs{$id}{'authentication'} ne $macs_authentication )                 { $wireless_macs{$id}{'authentication'}=$macs_authentication ;                 $poprawic_wpis+= 8;   $attrs4{'authentication'}=$macs_authentication; }
						if ( $wireless_macs{$id}{'client-tx-limit'} ne $macs_client_tx_limit )               { $wireless_macs{$id}{'client-tx-limit'}=$macs_client_tx_limit;                $poprawic_wpis+= 16;  $attrs4{'client-tx-limit'}=$macs_client_tx_limit; }
						if ( $wireless_macs{$id}{'ap-tx-limit'} ne $macs_ap_tx_limit )                       { $wireless_macs{$id}{'ap-tx-limit'}=$macs_ap_tx_limit;                        $poprawic_wpis+= 32;  $attrs4{'ap-tx-limit'}=$macs_ap_tx_limit; }
						if ( $wireless_macs{$id}{'signal-range'} ne $macs_signal_range )                     { $wireless_macs{$id}{'signal-range'}=$macs_signal_range;                      $poprawic_wpis+= 64;  $attrs4{'signal-range'}=$macs_signal_range; }
						if ( $wireless_macs{$id}{'private-pre-shared-key'} ne $macs_private_pre_shared_key ) { $wireless_macs{$id}{'private-pre-shared-key'}=$macs_private_pre_shared_key ; $poprawic_wpis+= 128; $attrs4{'private-pre-shared-key'}=$macs_private_pre_shared_key; }
						if ( $wireless_macs{$id}{'private-key'} ne $macs_private_key )                       { $wireless_macs{$id}{'private-key'}=$macs_private_key;                        $poprawic_wpis+= 256; $attrs4{'private-key'}=$macs_private_key; }
						if ( $wireless_macs{$id}{'comment'} ne $name )                                       { $wireless_macs{$id}{'comment'}=$name;                                        $poprawic_wpis+= 512; $attrs4{'comment'}=$name; }
						if ( $poprawic_wpis and $wireless_macs{$id}{'LMS'} < 2 ) {
							if (!$quiet) { print STDERR "acl jest do poprawy ($poprawic_wpis) -> "; }
							if ($info) { print STDERR "acl jest do poprawy ($poprawic_wpis) -> "; }
							$attrs4{'.id'} = $id;
							my($retval4,@results4)=Mtik::mtik_cmd('/interface/wireless/access-list/set',\%attrs4);
							sleep ($api_delay);
							print STDERR "ret: $retval4 -> ";
							if ($retval4 != 1) {
								print STDERR "BLAD przy zmianie acl! || "; }
							else { if (!$quiet) { print STDERR "OK(set_acl) || "; } }
						}
						else { if (!$quiet) { print STDERR "OK || "; } }
						$wireless_macs{$id}{'LMS'} = 1;
					} # end of if ( ($wireless_macs{$id}{'mac-address'} eq $cmac ) and ( $wireless_macs{$id}{'interface'} eq $iface) ) 
				    } # end of foreach my $id (keys (%wireless_macs)) 
				} #end of if ($acl_enable) 

				if (!$zarejestrowany and $acl_enable) {
					print STDERR "brak acl -> ";
					my %attrs2; 
					$attrs2{'mac-address'}=$cmac; 
					$attrs2{'comment'}=$name; 
					$attrs2{'disabled'}=$macs_disabled; 
					$attrs2{'ap-tx-limit'}=$macs_ap_tx_limit; 
					$attrs2{'authentication'}=$macs_authentication; 
					$attrs2{'client-tx-limit'}=$macs_client_tx_limit; 
					$attrs2{'forwarding'}=$macs_forwarding; 
					$attrs2{'interface'}=$iface; 
					$attrs2{'private-algo'}=$macs_private_algo; 
					$attrs2{'private-key'}=$macs_private_key; 
					$attrs2{'private-pre-shared-key'}=$macs_private_pre_shared_key; 
					$attrs2{'signal-range'}=$macs_signal_range;
					my($retval2,@results2)=Mtik::mtik_cmd('/interface/wireless/access-list/add',\%attrs2);
					sleep ($api_delay);
					print STDERR "ret: $retval2 -> ";
#		print STDERR " error: $Mtik::error_msg\n";
					if ($retval2 < 2) {
						if (!$quiet) { print STDERR "OK(add_acl) || "; }
					}
					else { print "BLAD!(add_acl) || "; }
				}
####### acl ^

####### dhcp v

				my $dopisany = 0;
				if ($dhcp_enable) {
                                    my $poprawic_wpis_dhcp=0;
                                    # teraz musimy sprawdzic lease z dhcp-server
                                    # jesli mamy taki wpis, to porownujemy wartosci
				    # sprawdza istnienie mac lub ipaddr
				    # problem: zmiana mac adresu pomiedzy istniejace IP - obejscie poprzez disable, 
				    # a nastepnie enable, gdy bedzie kopia to error i remove
				    foreach my $id (keys (%wireless_dhcp)) {
#                                        if (!$quiet) { print STDERR "_1_"; }
#                                        if (!$quiet) { print STDERR "1. dhcp $wireless_dhcp{$id}{'mac-address'} $wireless_dhcp{$id}{'address'} .$wireless_dhcp{$id}{'dynamic'}. > "; }
                                        if ( ( ($wireless_dhcp{$id}{'mac-address'} eq $cmac ) || ($wireless_dhcp{$id}{'address'} eq $ipaddr) ) and ($wireless_dhcp{$id}{'dynamic'} eq 'false') ) {
                                                if (!$quiet) { print STDERR "dhcp istnieje -> "; }
#                                                if (!$quiet) { print STDERR "2. dhcp .$wireless_dhcp{$id}{'dynamic'}. istnieje -> "; }
#                                                if (!$quiet) { print STDERR "2. dhcp $wireless_dhcp{$id}{'mac-address'} $wireless_dhcp{$id}{'address'} .$wireless_dhcp{$id}{'dynamic'}. istnieje -> "; }
                                                $dopisany=1;
                                                my $poprawic_wpis_dhcp=0;
                                                my %attrs8;
                                                # jesli juz dodany, to trzeba sprawdzic wszystkie atrybuty i ewentualnie poprawic
                                                if ( $wireless_dhcp{$id}{'address'} ne $ipaddr )	{ $wireless_dhcp{$id}{'address'}=$ipaddr;	$poprawic_wpis_dhcp+= 1;	$attrs8{'address'}=$ipaddr; }
						if ( $wireless_dhcp{$id}{'mac-address'} ne $cmac )	{ $wireless_dhcp{$id}{'mac-address'}=$cmac;	$poprawic_wpis_dhcp+= 2;	$attrs8{'mac-address'}=$cmac; }
						if ( $wireless_dhcp{$id}{'comment'} ne $name )		{ $wireless_dhcp{$id}{'comment'}=$name;		$poprawic_wpis_dhcp+= 4;	$attrs8{'comment'}=$name; }
						if ( $wireless_dhcp{$id}{'server'} ne $server )		{ $wireless_dhcp{$id}{'server'}=$server;	$poprawic_wpis_dhcp+= 8;	$attrs8{'server'}=$server; }
                                                if ( $poprawic_wpis_dhcp and $wireless_dhcp{$id}{'LMS'} < 2 ) {
                                                        if (!$quiet) { print STDERR "dhcp jest do poprawy ($poprawic_wpis_dhcp) -> "; }
                                                        if ($info) { print STDERR "dhcp jest do poprawy ($poprawic_wpis_dhcp) -> "; }
                                                        $attrs8{'.id'} = $id;
                                                        # przed zapisaniem zmian wpis ma byc disabled, a na koniec enabled by ominac error
                                                        $attrs8{'disabled'} = 'yes';
                                                        my($retval8,@results8)=Mtik::mtik_cmd('/ip/dhcp-server/lease/set',\%attrs8);
                                                        sleep ($api_delay);
                                                        print STDERR "ret: $retval8 -> ";
                                                        if ($retval8 != 1) {
                                                                print STDERR "BLAD przy zmianie wpisu dhcp! pewno jest juz taki mac lub ip|| "; }
                                                        else { if (!$quiet) { print STDERR "OK(set_dhcp) || "; } }
							# enable dla edytowanego wpisu
                                                        $attrs8{'disabled'} = 'no';
							my($retval8,@results8)=Mtik::mtik_cmd('/ip/dhcp-server/lease/set',\%attrs8);
							# kasujemy disabled zakonczony errorem
							my %attrs10;
							$attrs10{'.id'} = $id;
							if ($Mtik::error_msg) { Mtik::mtik_cmd('/ip/dhcp-server/lease/remove',\%attrs10 ) ;}
                                                } # koniec poprawiania wpisow
                                                else { if (!$quiet) { print STDERR "OK || "; } }
                                                $wireless_dhcp{$id}{'LMS'} = 1;
                                        } # end of if ( ($wireless_macs{$id}{'mac-address'} eq $cmac ) and ( $wireless_macs{$id}{'interface'} eq $iface) ) 
                                    if ($wireless_dhcp{$id}{'dynamic'} eq 'true') {
                                            if (!$quiet) { print STDERR "dhcp $wireless_dhcp{$id}{'mac-address'} $wireless_dhcp{$id}{'address'} .$wireless_dhcp{$id}{'dynamic'}. usunac -> "; }
					my %attrs10;
					$attrs10{'.id'} = $id;
					Mtik::mtik_cmd('/ip/dhcp-server/lease/remove',\%attrs10 ) ;
                                    }
                                    } # end of foreach my $id (keys (%wireless_macs)) 
				}
				    if (!$dopisany and $dhcp_enable) {
                                        print STDERR "brak dhcp, dodaje -> ";
					my %attrs7; 
					$attrs7{'address'} = $ipaddr; 
					$attrs7{'mac-address'} = $cmac; 
					$attrs7{'server'} = $server; 
					$attrs7{'comment'} = $name;
					my($retval7,@results7)=Mtik::mtik_cmd('/ip/dhcp-server/lease/add',\%attrs7);
                                        sleep ($api_delay);
                                        print STDERR "ret: $retval7 -> ";
                                        if ($retval7 != 1) {
                                                print "BLAD przy dodawaniu wpisu dhcp!! || "; 
						print " error: $Mtik::error_msg\n";
                                                }
                                        else { if (!$quiet) { print STDERR "OK(add_dhcp) || "; } }
                                	}
####### dhcp ^

####### arp v
# zapetlic trzeba by dodawane byly arpy z dodatkowego pola
# ew. dodatkowy ip traktowany wspolnie razem z podstawowym
# tylko jak to sie zachowa przy weryfikacji istniejacych?
				my $dopisany = 0;
				if ($arp_enable) {
                                    my $poprawic_wpis_arp=0;
				    foreach my $id (keys (%wireless_arp)) {
                                        if ( ($wireless_arp{$id}{'mac-address'} eq $cmac ) || ($wireless_arp{$id}{'address'} eq $ipaddr) ) {
                                                if (!$quiet) { print STDERR "arp istnieje -> "; }
                                                $dopisany=1;
                                                my $poprawic_wpis_arp=0;
                                                my %attrs8;
                                                # jesli juz dodany, to trzeba sprawdzic wszystkie atrybuty i ewentualnie poprawic
#                                        	if (!$quiet) { print STDERR "( .. $wireless_arp{$id}{'interface'} .. $iface .. "; }
                                                if ( $wireless_arp{$id}{'address'} ne $ipaddr )		{ $wireless_arp{$id}{'address'}=$ipaddr;	$poprawic_wpis_arp+= 1;	 $attrs8{'address'}=$ipaddr; }
						if ( $wireless_arp{$id}{'mac-address'} ne $cmac )	{ $wireless_arp{$id}{'mac-address'}=$cmac;	$poprawic_wpis_arp+= 2;	 $attrs8{'mac-address'}=$cmac; }
						if ( $wireless_arp{$id}{'comment'} ne $name )		{ $wireless_arp{$id}{'comment'}=$name;		$poprawic_wpis_arp+= 4;	 $attrs8{'comment'}=$name; }
						if ( $wireless_arp{$id}{'interface'} ne $iface )	{ $wireless_arp{$id}{'interface'}=$iface;	$poprawic_wpis_arp+= 8;	 $attrs8{'interface'}=$iface; }
                                                if ( $poprawic_wpis_arp and $wireless_arp{$id}{'LMS'} < 2 ) {
                                                        if (!$quiet) { print STDERR "arp jest do poprawy ($poprawic_wpis_arp) -> "; }
                                                        if ($info) { print STDERR "arp jest do poprawy ($poprawic_wpis_arp) -> "; }
                                                        $attrs8{'.id'} = $id;
                                                        # przed zapisaniem zmian wpis ma byc disabled, a na koniec enabled by ominac error
                                                        $attrs8{'disabled'} = 'yes';
                                                        my($retval8,@results8)=Mtik::mtik_cmd('/ip/arp/set',\%attrs8);
                                                        sleep ($api_delay);
                                                        print STDERR "ret: $retval8 -> ";
                                                        if ($retval8 != 1) {
                                                                print STDERR "BLAD przy zmianie wpisu arp! pewno jest juz taki mac lub ip|| "; }
                                                        else { if (!$quiet) { print STDERR "OK(set_arp) || "; } }
							# enable dla edytowanego wpisu
                                                        $attrs8{'disabled'} = 'no';
							my($retval8,@results8)=Mtik::mtik_cmd('/ip/arp/set',\%attrs8);
							# kasujemy disabled zakonczony errorem
							my %attrs10;
							$attrs10{'.id'} = $id;
							if ($Mtik::error_msg) { Mtik::mtik_cmd('/ip/arp/remove',\%attrs10 ) ;}
                                                } # koniec poprawiania wpisow
                                                else { if (!$quiet) { print STDERR "OK || "; } }
                                                $wireless_arp{$id}{'LMS'} = 1;

                                        } # end of if ( ($wireless_macs{$id}{'mac-address'} eq $cmac ) and ( $wireless_macs{$id}{'interface'} eq $iface) ) 
                                    } # end of foreach my $id (keys (%wireless_macs)) 
				    }
# jezeli nie ma takiego wpisu to trzeba go dodac:
				    if (!$dopisany and $arp_enable) {
# arp z podstawowego pola:
                                        print STDERR "brak arp, dodaje -> ";
					my %attrs3; 
					$attrs3{'address'} = $ipaddr; 
					$attrs3{'mac-address'} = $cmac; 
					$attrs3{'comment'} = $name;
					$attrs3{'interface'} = $iface; 
					my($retval3,@results3)=Mtik::mtik_cmd('/ip/arp/add',\%attrs3);
                                        sleep ($api_delay);
                                        print STDERR "ret: $retval3 -> ";
                                        if ($retval3 != 1) {
                                                print "BLAD przy dodawaniu wpisu arp!! || "; 
#						print " error: $Mtik::error_msg\n";
                                                }
                                        else { if (!$quiet) { print STDERR "OK(add_arp) "; } }

                                	} #endof if (!$dopisany and $arp_enable)
####### arp ^




####### bloklista v
# zapetlic trzeba by dodawane byly ipki z dodatkowego pola
# ew. dodatkowy ip traktowany wspolnie razem z podstawowym
# tylko jak to sie zachowa przy weryfikacji istniejacych?

# blad: z bloklisty nie sa usuwane wpisy nieistniejacych komputerow (maly problem, ale jednak jest)

				my $dopisany = 0;
				if ($bloklista_enable) {
                                    my $poprawic_wpis_bloklista=0;
				    foreach my $id (keys (%wireless_bloklista)) {
                                        if  ($wireless_bloklista{$id}{'address'} eq $ipaddr and !$access)  {
                                                if (!$quiet) { print STDERR "wpis w blokliscie istnieje -> "; }
                                                $dopisany=1;
                                                my $poprawic_wpis_bloklista=0;
                                                my %attrs15;
                                                # jesli juz dodany, to trzeba sprawdzic wszystkie atrybuty i ewentualnie poprawic
                                                if ( $wireless_bloklista{$id}{'address'} ne $ipaddr )	{ $wireless_bloklista{$id}{'address'}=$ipaddr;	$poprawic_wpis_bloklista+= 1;	 $attrs15{'address'}=$ipaddr; }
						if ( $wireless_bloklista{$id}{'comment'} ne $name )	{ $wireless_bloklista{$id}{'comment'}=$name;	$poprawic_wpis_bloklista+= 2;	 $attrs15{'comment'}=$name; }
                                                if ( $poprawic_wpis_bloklista and $wireless_bloklista{$id}{'LMS'} < 2 ) {
                                                        if (!$quiet) { print STDERR "wpis w blokliscie jest do poprawy ($poprawic_wpis_bloklista) -> "; }
                                                        if ($info) { print STDERR "wpis w blokliscie jest do poprawy ($poprawic_wpis_bloklista) -> "; }
                                                        $attrs15{'.id'} = $id;
                                                        # przed zapisaniem zmian wpis ma byc disabled, a na koniec enabled by ominac error
                                                        $attrs15{'disabled'} = 'yes';
                                                        my($retval15,@results15)=Mtik::mtik_cmd('/ip/firewall/address-list/set',\%attrs15);
                                                        sleep ($api_delay);
                                                        print STDERR "ret: $retval15 -> ";
                                                        if ($retval15 != 1) {
                                                                print STDERR "BLAD przy zmianie wpisu w bloklist! pewno jest juz taki ip|| "; }
                                                        else { if (!$quiet) { print STDERR "OK(set_blokllst) || "; } }
							# enable dla edytowanego wpisu
                                                        $attrs15{'disabled'} = 'no';
							my($retval15,@results15)=Mtik::mtik_cmd('/ip/firewall/address-list/set',\%attrs15);
							# kasujemy disabled zakonczony errorem
							my %attrs16;
							$attrs16{'.id'} = $id;
							if ($Mtik::error_msg) { Mtik::mtik_cmd('/ip/firewall/address-list/remove',\%attrs16 ) ;}
                                                } # koniec poprawiania wpisow
                                                else { if (!$quiet) { print STDERR "OK || "; } }
                                                $wireless_bloklista{$id}{'LMS'} = 1;

                                        } # end of if ( ($wireless_macs{$id}{'mac-address'} eq $cmac ) and ( $wireless_macs{$id}{'interface'} eq $iface) ) 
                                    } # end of foreach my $id (keys (%wireless_macs)) 
				    }
# jezeli nie ma takiego wpisu to trzeba go dodac:
				    if (!$dopisany and $bloklista_enable and !$access ) {
# z podstawowego pola:
                                        print STDERR "brak wpisu w bloklist, dodaje -> ";
					my %attrs17; 
					$attrs17{'address'} = $ipaddr; 
					$attrs17{'comment'} = $name;
					$attrs17{'list'} = $bloklista_nazwalisty;
					my($retval17,@results17)=Mtik::mtik_cmd('/ip/firewall/address-list/add',\%attrs17);
                                        sleep ($api_delay);
                                        print STDERR "rett: $retval17 -> ";
                                        if ($retval17 != 1) {
                                                print "BLAD przy dodawaniu wpisu w bloklist!! || "; 
						print " error: $Mtik::error_msg\n";
                                                }
                                        else { if (!$quiet) { print STDERR "OK(add_bloklist) "; } }

                                	} #endof if (!$dopisany and $arp_enable)

####### queue v
				if ($queue_enable) {
				    my $poprawic_wpis_simple=0;
				    my $poprawic_wpis_simple_n=0;

				if ($ipaddr_pub ne "0.0.0.0") 
				{ 
				    $ipaddr_ = $ipaddr.", ".$ipaddr_pub;
				    $ipaddr_32 = $ipaddr."/32,".$ipaddr_pub."/32";
				}
				else {
				    $ipaddr_ = $ipaddr;
				    $ipaddr_32 = $ipaddr."/32";
				}

				    # teraz musimy sprawdzic kolejke simple
				    # jesli mamy taki wpis, to porownujemy wartosci
### queue dzien v
				    if ( defined ($wireless_queues{$name_kolejka}{'name'}) ) {
					if (!$quiet) { print STDERR "queue istnieje -> "; }
#print STDERR " speed: $wireless_queues{$name_kolejka}{'target'}. $ipaddr . $ipaddr_32 ";
					my %attrs5;
					if ( $wireless_queues{$name_kolejka}{'max-limit'} ne $max_limit )   { $wireless_queues{$name_kolejka}{'max-limit'}=$max_limit;  $poprawic_wpis_simple+= 1;  $attrs5{'max-limit'} = $max_limit; }
					if ( $wireless_queues{$name_kolejka}{'time'} ne $simple_time )      { $wireless_queues{$name_kolejka}{'time'}=$simple_time;     $poprawic_wpis_simple+= 4;  $attrs5{'time'} = $simple_time; }
					if ( $wireless_queues{$name_kolejka}{'target'} ne $ipaddr_32 )      { $wireless_queues{$name_kolejka}{'target'}=$ipaddr_32;  	$poprawic_wpis_simple+= 2;  $attrs5{'target'} = $ipaddr_32; }
					if ( $poprawic_wpis_simple ) {
						if (!$quiet) { print STDERR "queue jest do poprawy ($poprawic_wpis_simple): "; }
						if ($info) { print STDERR "queue jest do poprawy ($poprawic_wpis_simple): "; }
				    		    $attrs5{'.id'}=$wireless_queues{$name_kolejka}{'.id'};
						    my($retval5,@results5)=Mtik::mtik_cmd('/queue/simple/set',\%attrs5);
						    sleep ($api_delay);
						    if ($retval5 != 1) {
							print STDERR "BLAD przy zmianie wpisu queue!\n"; }
						    else { if (!$quiet) { print STDERR "OK(set_queue)\n"; } }
					}
					$wireless_queues{$name_kolejka}{'LMS'} = 1; 
				    }
				    else {
					my %attrs1; 
					    $attrs1{'name'} = $name_kolejka; $attrs1{'target'} = $ipaddr_; $attrs1{'max-limit'} = $max_limit; $attrs1{'burst-limit'} = $simple_burst_limit; $attrs1{'burst-threshold'} = $simple_burst_threshold; $attrs1{'burst-time'} = $simple_burst_time; $attrs1{'disabled'} = $simple_disable; 
					$attrs1{'dst'} = $simple_dst_address; $attrs1{'limit-at'} = $simple_limit_at; $attrs1{'parent'} = $simple_parent; $attrs1{'priority'} = $simple_priority; $attrs1{'queue'} = $simple_queue; $attrs1{'time'} = $simple_time; $attrs1{'total-queue'} = $simple_total_queue;
					my($retval1,@results1)=Mtik::mtik_cmd('/queue/simple/add',\%attrs1);
					sleep ($api_delay);
					print STDERR "ret: $retval1 -> ";
					if ($retval1 != 1) {
						print "BLAD przy dodawaniu queue!\n"; }
					else { if (!$quiet) { print STDERR "OK(add_queue) "; } }
				    }
### queue dzien ^
### queue noc v
				    if ( defined ($wireless_queues{$name_kolejka."_\$"}{'name'}) ) {
					if (!$quiet) { print STDERR "queue_n istnieje -> "; }
					my %attrs11;
					if ( $wireless_queues{$name_kolejka."_\$"}{'max-limit'} ne $max_limit_n )       { $wireless_queues{$name_kolejka."_\$"}{'max-limit'}=$max_limit_n;      $poprawic_wpis_simple_n+= 1;  $attrs11{'max-limit'} = $max_limit_n; }
					if ( $wireless_queues{$name_kolejka."_\$"}{'target'} ne $ipaddr_32 )  		{ $wireless_queues{$name_kolejka."_\$"}{'target'}=$ipaddr_32;  		$poprawic_wpis_simple_n+= 2;  $attrs11{'target'} = $ipaddr_32; }
					if ( $wireless_queues{$name_kolejka."_\$"}{'time'} ne $simple_time_n )          { $wireless_queues{$name_kolejka."_\$"}{'time'}=$simple_time_n;         $poprawic_wpis_simple_n+= 4;  $attrs11{'time'} = $simple_time_n; }
					if ( $poprawic_wpis_simple_n ) {
						if (!$quiet) { print STDERR "queue_n jest do poprawy: "; }
						if ($info) { print STDERR "queue_n jest do poprawy: "; }
				    		    $attrs11{'.id'}=$wireless_queues{$name_kolejka."_\$"}{'.id'};
						    my($retval11,@results11)=Mtik::mtik_cmd('/queue/simple/set',\%attrs11);
						    sleep ($api_delay);
						    if ($retval11 != 1) {
							print STDERR "BLAD przy zmianie wpisu queue_n!\n"; }
						    else { if (!$quiet) { print STDERR "OK(set_queue_n)\n"; } }
					}
					$wireless_queues{$name_kolejka."_\$"}{'LMS'} = 1; 
				    }
				    else {
					print STDERR "dodawanie queue_noc -> ";
					my %attrs12; 
					    $attrs12{'name'} = $name_kolejka; $attrs12{'target'} = $ipaddr_; $attrs12{'max-limit'} = $max_limit; $attrs12{'burst-limit'} = $simple_burst_limit; $attrs12{'burst-threshold'} = $simple_burst_threshold; $attrs12{'burst-time'} = $simple_burst_time; $attrs12{'disabled'} = $simple_disable;
					$attrs12{'dst'} = $simple_dst_address; $attrs12{'limit-at'} = $simple_limit_at; $attrs12{'parent'} = $simple_parent; $attrs12{'priority'} = $simple_priority; $attrs12{'queue'} = $simple_queue; $attrs12{'time'} = $simple_time; $attrs12{'total-queue'} = $simple_total_queue;
					$attrs12{'name'} = $name_kolejka."_\$"; $attrs12{'max-limit'} = $max_limit_n; $attrs12{'time'} = $simple_time_n;
					my($retval12,@results1)=Mtik::mtik_cmd('/queue/simple/add',\%attrs12);
					sleep ($api_delay);
					print STDERR "ret: $retval12 -> ";
					if ($retval12 != 1) {
						print "BLAD przy dodawaniu queue!\n"; }
					else { if (!$quiet) { print STDERR "OK(add_queue) "; } }
				    }
### queue noc ^
				{ if (!$quiet) { print STDERR "OK \n"; } }
				} # end of if ($queue_enable) 
####### queue ^


			} # end of if(matchip($row2->{'ipaddr'},$row->{'address'},$row->{'mask'})) 
		} # end of while (my $row2 = $dbq2->fetchrow_hashref()) 



		if(!$quiet and ( $acl_enable or $queue_enable or $dhcp_enable )) { print STDERR "\n";}
		# poniewa¿ wykonuje siê to po ka¿dej zdefiniowanej sieci, nie kasujê wpiso z innych sieciowek w tym i z ustawionym interfejsem all
		if ($acl_enable) {
		    foreach my $id (keys (%wireless_macs)) {
			if (( $wireless_macs{$id}{'interface'} eq $iface) and ($wireless_macs{$id}{'LMS'} < 1 )) {
				print STDERR "usuwam zbedne $wireless_macs{$id}{'mac-address'} @ $wireless_macs{$id}{'interface'} -> ";
				my %attrs6; $attrs6{'.id'}=$wireless_macs{$id}{'.id'};
				my($retval6,@results6)=Mtik::mtik_cmd('/interface/wireless/access-list/remove',\%attrs6);
				sleep ($api_delay);
				print STDERR "ret: $retval6 -> ";
				if ($retval6 == 1) {
					if (!$quiet) { print STDERR "OK!(del_acl) || ";} }
				else { print "BLAD!(del_acl)\n"; }
			}
		    }
		}

		if ($dhcp_enable) {
                    foreach my $id (keys (%wireless_dhcp)) {
# sprawdzenie, czy analizowany IP nalezy do sprawdzanej sieci, jezeli nie to nie usuwa go
	    		$ipjestwsieci = matchip($wireless_dhcp{$id}{'address'},$address,$mask);
#print STDERR "\n . $ipjestwsieci . net: $address maska: $mask . ip: $wireless_dhcp{$id}{'address'} \n";
                        if ($wireless_dhcp{$id}{'LMS'} < 1 and $ipjestwsieci) {
#                                print STDERR "uwaga dhcp: $wireless_dhcp{$id}{'LMS'} | ";
                                print STDERR "usuwam zbedne dhcp: $wireless_dhcp{$id}{'mac-address'} -> ";
                                my %attrs9; $attrs9{'.id'}=$wireless_dhcp{$id}{'.id'};
                                my($retval9,@results9)=Mtik::mtik_cmd('/ip/dhcp-server/lease/remove',\%attrs9);
                                sleep ($api_delay);
                                print STDERR "ret: $retval9 -> ";
                                if ($retval9 == 1) {
                                        if (!$quiet) { print STDERR "OK!(del_dhcp)\n";} 

                                        }
                                else { print "BLAD!(del_dhcp)\n"; }
                        }
                    }
                }

		if ($arp_enable) {
                    foreach my $id (keys (%wireless_arp)) {
# sprawdzenie, czy analizowany IP nalezy do sprawdzanej sieci, jezeli nie to nie usuwa go
			$ipjestwsieci = matchip($wireless_arp{$id}{'address'},$address,$mask);
#print STDERR "\n . $ipjestwsieci . net: $address maska: $mask . ip: $wireless_arp{$id}{'address'} \n";
                        if ($wireless_arp{$id}{'LMS'} < 1 and $ipjestwsieci) {
#                                print STDERR "uwaga arp: $wireless_arp{$id}{'LMS'} | ";
                                print STDERR "usuwam zbedne arp: $wireless_arp{$id}{'mac-address'} -> ";
                                my %attrs9; $attrs9{'.id'}=$wireless_arp{$id}{'.id'};
                                my($retval9,@results9)=Mtik::mtik_cmd('/ip/arp/remove',\%attrs9);
                                sleep ($api_delay);
                                print STDERR "ret: $retval9 -> ";
                                if ($retval9 == 1) {
                                        if (!$quiet) { print STDERR "OK!(del_arp)\n";} 

                                        }
                                else { print "BLAD!(del_arp)\n"; }
                        }
                    }
                }

# usuwamy kolejki ktore nie maja powiazania
		if ($queue_enable) {
		    foreach my $name_queues (keys (%wireless_queues)) {
# sprawdzenie, czy analizowany IP nalezy do sprawdzanej sieci, jezeli nie to nie usuwa go
		    $ipjestwsieci = matchip($wireless_queues{$name_queues}{'target'},$address,$mask);
#print STDERR "\n . $ipjestwsieci . net: $address maska: $mask . ip: $wireless_queues{$name_queues}{'target'} \n";
	# wykonujemy tylko raz na koniec
			if ($wireless_queues{$name_queues}{'LMS'} < 1 and $ipjestwsieci) {
			    print STDERR "usuwam zbedne kolejki ($name_queues) -> ";
			    my %attrs7; $attrs7{'.id'}=$wireless_queues{$name_queues}{'.id'};
			    my($retval7,@results7)=Mtik::mtik_cmd('/queue/simple/remove',\%attrs7);
			    sleep ($api_delay);
			    print STDERR "ret: $retval7 -> ";
			    if ($retval7 == 1) {
				if (!$quiet) { print "OK!(del_queue)\n"; } }
			    else { print "BLAD!(del_queue)\n"; }
			}
		    }
		}



		if ($bloklista_enable) {
                    foreach my $id (keys (%wireless_bloklista)) {
# sprawdzenie, czy analizowany IP nalezy do sprawdzanej sieci, jezeli nie to nie usuwa go
			$ipjestwsieci = matchip($wireless_bloklista{$id}{'address'},$address,$mask);
#print STDERR "\n . $ipjestwsieci . net: $address maska: $mask . ip: $wireless_bloklista{$id}{'address'} \n";
                        if ($wireless_bloklista{$id}{'LMS'} < 1 and $ipjestwsieci) {
#                                print STDERR "uwaga bloklista: $wireless_bloklista{$id}{'LMS'} | ";
                                print STDERR "usuwam zbedne bloklista: $wireless_bloklista{$id}{'address'} -> ";
                                my %attrs14; $attrs14{'.id'}=$wireless_bloklista{$id}{'.id'};
                                my($retval14,@results14)=Mtik::mtik_cmd('/ip/firewall/address-list/remove',\%attrs14);
                                sleep ($api_delay);
                                print STDERR "ret: $retval14 -> ";
                                if ($retval14 == 1) {
                                        if (!$quiet) { print STDERR "OK!(del_bloklista)\n";} 

                                        }
                                else { print "BLAD!(del_bloklista)\n"; }
                        }
                    }
                }

	} # end of while (my $row = $dbq->fetchrow_hashref()) {
} # end of foreach my $key (@networks) {

				Mtik::logout;
			} # end of if (Mtik::login($mkhost,$mkuser,$mkpass)) {
				else { print STDERR "Blad polaczenia!\n"; }
# zapisanie do bazy koniec przeladowania
			my $utsfmt = "UNIX_TIMESTAMP()";
            		my $sdbq = $dbase->prepare("UPDATE hosts SET reload=0, lastreload=$utsfmt  WHERE name LIKE UPPER('$hostname') and reload=2");
            		$sdbq->execute() || die $sdbq->errstr;
		} # end of if(sprawdz_zmiany() or $force) {
	} # end of foreach my $row(@list) {
	$dbase->disconnect();
} # end of if ( polacz_z_baza() ) {


######################################################################################
sub mask2prefix($) {
	my $mask = shift @_;
	my @tmp = split('\.',$mask,4);
	my $q = sprintf("%b%b%b%b",$tmp[0],$tmp[1],$tmp[2],$tmp[3]);
	$q =~ s/0*$//;
	if ($q =~ /0/) {
		print " You idiot. error in mask\n";
	}
	my $len = length($q) ;
	return $len;
}

sub matchip($$$) {
	my ($ip,$net,$mask) = @_;
	my $prefix = mask2prefix($mask);
	my $bmask = 2**32 - 2**(32-$prefix);
	my @net = split('\.',$net,4);
	my $bnet = dotquad2u32($net);
	if(($bnet & $bmask)!= $bnet) {
		print "EEediot net &mask != net\n"; return 1==0
	}
	my $bip = dotquad2u32($ip);
	return (($bip&$bmask) == $bnet);
}

sub dotquad2u32($) {
	my $dq = shift||'0.0.0.0';
	my @dq = split('\.',$dq,4);
	return ((($dq[0] << 8) + $dq[1] << 8) + $dq[2] << 8) + $dq[3];
}

sub u32todotquad($) {
	my $p = shift @_;
	return sprintf "%d.%d.%d.%d", ($p>>24)&0xff,($p>>16)&0xff, ($p>>8)&0xff,$p&0xff;
}

sub localtime2() {
	if($fakedate) {
		my @fakedate = split(/\//, $fakedate);
		return localtime(timelocal(0,0,0,$fakedate[2],$fakedate[1]-1,$fakedate[0]));
	}
	else {
		return localtime();
	}
}

sub taryfy($$) {
	my ($user_id,$user_ip) = @_;
	my $tariff_id = 0;
	my $max_down = 0;
	my $max_id = 0;
	my $currtime = strftime("%s",localtime2());
	# najpierw pobieramy w naturalny sposob aktywna taryfe
	my $dbq1 = $dbase->prepare("SELECT tariffid FROM assignments WHERE customerid = $user_id AND (datefrom <= $currtime OR datefrom = 0) AND (dateto > $currtime OR dateto = 0) AND suspended = 0");
	$dbq1->execute();
	while (my $row1 = $dbq1->fetchrow_hashref()) {
		$tariff_id = $row1->{'tariffid'};
		my $dbq2 = $dbase->prepare("SELECT id, downceil  FROM tariffs WHERE id = $row1->{'tariffid'} AND downceil <> 0");
		$dbq2->execute();
		while ( my $row2 = $dbq2->fetchrow_hashref()) {
			# szukamy najwiekszej taryfy
			if ( $row2->{'downceil'} > $max_down ) {
				$max_down = $row2->{'downceil'};
				$max_id = $row2->{'id'};
			}
		}
	}
	# jesli zostala jakas taryfa z id > 0 to zwroc i zakoncz
	if($max_id > 0 ) {
		return $max_id;
	}
# wychaszowane, by wyciagac tylko aktywna taryfe
#	# nie znaleziono aktywnej taryfy wiec szukam jeszcze nie rozpoczetych
#	$dbq1 = $dbase->prepare("SELECT tariffid FROM assignments WHERE customerid = $user_id AND suspended = 0");
#	$dbq1->execute();
#	while (my $row1 = $dbq1->fetchrow_hashref()) {
#		$tariff_id = $row1->{'tariffid'};
#		my $dbq2 = $dbase->prepare("SELECT id, downceil  FROM tariffs WHERE id = $row1->{'tariffid'}");
#		$dbq2->execute();
#		while ( my $row2 = $dbq2->fetchrow_hashref()) {
#			# szukamy najwiêkszej taryfy
#			if ( $row2->{'downceil'} > $max_down ) {
#				$max_down = $row2->{'downceil'};
#				$max_id = $row2->{'id'};
#			}
#		}
#	}
#	# je¶li zosta³a jaka¶ taryfa z id > 0 to zwróc i zakoñcz
#	if($max_id > 0 ) {
#		return $max_id;
#	}
#
#	# ostatnia deska ratunku - taryfa zawieszona
#	$dbq1 = $dbase->prepare("SELECT tariffid FROM assignments WHERE customerid = $user_id");
#	$dbq1->execute();
#	while (my $row1 = $dbq1->fetchrow_hashref()) {
#		$tariff_id = $row1->{'tariffid'};
#		my $dbq2 = $dbase->prepare("SELECT id, downceil  FROM tariffs WHERE id = $row1->{'tariffid'}");
#		$dbq2->execute();
#		while ( my $row2 = $dbq2->fetchrow_hashref()) {
#			# szukamy najwiêkszej taryfy
#			if ( $row2->{'downceil'} > $max_down ) {
#				$max_down = $row2->{'downceil'};
#				$max_id = $row2->{'id'};
#			}
#		}
#	}
	# jesli tariff_id = 0 to nie znalaz³ taryfy
	return $max_id;
}

sub polacz_z_baza() {
	if($dbtype eq "mysql") {
		$dbase = DBI->connect("DBI:mysql:database=$dbname;host=$dbhost","$dbuser","$dbpasswd", { RaiseError => 1 });
	}
	elsif($dbtype eq "postgres") {
		$dbase = DBI->connect("DBI:Pg:dbname=$dbname;host=$dbhost","$dbuser","$dbpasswd", { RaiseError => 1 });
	}
	else {
		print STDERR "Fatal error: unsupported database type: $dbtype, exiting.\n";
		exit 1;
	}
}

sub sprawdz_zmiany() {
                   if($debug) {print STDERR "sprawdzam $hostname: "; }
       my $utsfmt = "UNIX_TIMESTAMP()";
       my $dbq1 = $dbase->prepare("SELECT name, lastreload, reload FROM hosts WHERE name LIKE UPPER('$hostname')");
       $dbq1->execute();
       while ( my $row1 = $dbq1->fetchrow_hashref()) {
               if ( $row1->{'reload'} ne 1 ) {
                   if($debug) {print STDERR "nie trzeba przeladowywac\n"; }
                       return 0;
               }
               else {
                   if($debug) {print STDERR "przeladowanie konieczne\n"; }
                       my $sdbq = $dbase->prepare("UPDATE hosts SET reload=2, lastreload=$utsfmt  WHERE name LIKE UPPER('$hostname') and reload=1");
                       $sdbq->execute() || die $sdbq->errstr;
                       return 1;
               }
       }
}
