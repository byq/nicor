#!/usr/bin/perl


use strict;
use DBI;
use Mtik;
use Config::IniFiles;
use Getopt::Long;
use Time::Local;
use POSIX qw(strftime mktime);
use vars qw($configfile $quiet $help $version $force $fakedate $mklistfile $error_msg);

$ENV{'PATH'}='/sbin:/usr/sbin:/usr/local/sbin:/bin:/usr/bin:/usr/local/bin:/etc/rc.d/:/etc/lms';

sub mask2prefix($);
sub matchip($$$);
sub dotquad2u32($);
sub u32todotquad($);
sub localtime2();
sub taryfy($$);
sub polacz_z_baza();
sub sprawdz_zmiany();

my $_version = '2.0.x';

my %options = (
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
(C) 2013-2014 byq

-C, --config-file=/etc/lms/lms.ini	alternate config file (default: /etc/lms/lms.ini);
-l, --mklist=/etc/lms/mikrotik.list	mikrotik's list file (default: /etc/lms/mikrotik.list);
-h, --help			print this help and exit;
-v, --version			print version info and exit;
-q, --quiet			suppress any output, except errors;
-f, --force			force reload specific mikrotik;

EOF
	exit 0;
}

if($version) {
	print STDERR <<EOF;
mikrotik, version $_version
(C) 2001-2006 LMS Developers
(C) 2009-20xx Emers, Wojtek
EOF
	exit 0;
}

if(!$configfile) {
	$configfile = "/etc/lms/lms.ini";
}

if(!$mklistfile) {
	$mklistfile = "/etc/lms/mikrotik.list";
}

if(!$quiet) {
	print STDOUT "mikrotik, version $_version\n";
	print STDOUT "(C) Copyright 2001-2006 LMS Developers\n";
	print STDOUT "(C) Copyright 2009-20xx Emers\n";
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

my $def_down=100;	# minimalny download dla osób bez taryfy, potrzebny by daæ dostêp dp stron serwisowych
my $def_up=100;		# minimalny upload dla osób bez taryfy, potrzebny by daæ dostêp dp stron serwisowych
my $aclprefix='LMS';	# przefix dodawany do wpisów generowanych automatycznie, przydatne, by odró¿niæ od statycznych
my $tariff_mult=1;	# mno¿nik uploadu i downloadu, dobrze ustawiæ >1, by MT nie traci³ mocy CPU na zarz±dzanie pasmem, gdy u¿ytkownik osi±ga warto¶æ graniczn± taryfy
my $macs_usunac='MT-';	# ignoruj urz±dzenia z tym prefixem w polu name, najczê¶ciej to sprzêt sieciowy, którego nie trzeba ograniczaæ
my $api_delay=0;	# czas (w sekundach) oczekiwania po zmianie/dokonaniu wpisu
my $acl_enable=0; 	# czy zarzadzac accesslista
my $queue_enable=0; 	# czy zarzadzac kolejkami
my $dhcp_enable=1;	# czy zarzadzac dhcp

#domy¶lne ustawienia regu³ki interface wireless access-list
my $macs_private_algo='none';
my $macs_disabled='false';
my $macs_forwarding='true';
my $macs_authentication='true';
my $macs_client_tx_limit='0';
my $macs_ap_tx_limit='0';
my $macs_signal_range='-120..120';
my $macs_private_pre_shared_key='';
my $macs_private_key='';

#domy¶lne ustawienia regu³ki simple queue
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
my $simple_queue = 'default-small/default-small';
my $simple_time = '8h-1d,sun,mon,tue,wed,thu,fri,sat';
my $simple_total_queue = 'default-small';

#domyslne ustawienia regulki dhcp-server lease

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
#print STDERR "test1 \n";

		if(sprawdz_zmiany() or $force) {
			if(!$quiet) { print STDERR "Konieczne przeladowanie mk: $hostname, host: $mkhost, user: $mkuser, pass: *****\n"; }
			if (Mtik::login($mkhost,$mkuser,$mkpass)) {





if(!$quiet) { print STDERR "Zalogowano\n"; }
if(!$quiet and $acl_enable) { print STDERR "Aktualnie dodane wpisy do access listy:\n---------------------------------------\n"; }
my(%wireless_macs) = Mtik::get_by_key('/interface/wireless/access-list/print','.id');
if ($Mtik::error_msg eq '' and $acl_enable) {
	foreach my $id (keys (%wireless_macs)) {
		if(!$quiet) { print STDERR " ID: $id\n"; }
		# zaznaczamy domy¶lnie ka¿dy wpis do usuniêcia
		$_=$wireless_macs{$id}{'comment'};
		if (/$macs_usunac/) { $wireless_macs{$id}{'LMS'} = '2'; }
		else { $wireless_macs{$id}{'LMS'} = '0'; }
	}
}
if(!$quiet and $dhcp_enable) { print STDERR "Aktualnie dodane wpisy do serwera dhcp:\n---------------------------------------\n"; }

my(%wireless_dhcp) = `ssh -l admin-ssh -i ./mt-test 192.168.44.2 "/ip dhcp-server lease print" | grep -v "Flags" | grep -v "ADDRESS" | grep -v '^[[:space:]]\*\$'`;

#if ($Mtik::error_msg eq '' and $dhcp_enable) {
#	foreach my $id (keys (%wireless_dhcp)) {
	foreach my $id (%wireless_dhcp) {
		if(!$quiet) { 
		print STDERR " ID: $id "; 
		}
		# zaznaczamy domyslnie kazdy wpis do usuniecia
#		$_=$wireless_dhcp{$id}{'comment'};
#		if (/$macs_usunac/) { $wireless_dhcp{$id}{'LMS'} = '2'; }
#		else { $wireless_dhcp{$id}{'LMS'} = '0'; }
	}
#}

if(!$quiet and $queue_enable) { print STDERR "\nAktualnie dodane kolejki queue simple:\n--------------------------------------\n"; }
my(%wireless_queues) = Mtik::get_by_key('/queue/simple/print','name');
if ($Mtik::error_msg eq '' and $queue_enable) {
	foreach my $name_queues (keys (%wireless_queues)) {
		if(!$quiet) { print STDERR " Name: $name_queues\n"; }
		# zaznaczamy domy¶lnie ka¿dy wpis do usuniêcia
		$_=$wireless_queues{$name_queues}{'comment'};
		if (/$macs_usunac/) { $wireless_queues{$name_queues}{'LMS'} = '2'; }
		else { $wireless_queues{$name_queues}{'LMS'} = '0'; }
	}
}

# koniec aktualnych danych



if(!$quiet and ( $acl_enable or $queue_enable or $dhcp_enable )) { print STDERR "\n";}
my @networks = split ' ', $mknetl;
foreach my $key (@networks) {
	my $dbq = $dbase->prepare("SELECT id, inet_ntoa(address) AS address, mask, interface, domain  FROM networks WHERE name = UPPER('$key')");
	$dbq->execute();
	if(!$quiet and ( $acl_enable or $queue_enable or $dhcp_enable ) ) { print STDERR "Sprawdzam siec: $key\n";}
	while (my $row = $dbq->fetchrow_hashref()) {
		my $dbq2 = $dbase->prepare("SELECT id, name, ipaddr, mac, ownerid FROM nodes WHERE name not like '%$macs_usunac%' ORDER BY ipaddr ASC");
		$dbq2->execute();
		my $iface = $row->{'domain'}; # nazwa interfejsu na MT przechowywana jest w polu domain w konfiguracji konkretnej sieci
		while (my $row2 = $dbq2->fetchrow_hashref()) {
			$row2->{'ipaddr'} = u32todotquad($row2->{'ipaddr'});
			if(matchip($row2->{'ipaddr'},$row->{'address'},$row->{'mask'})) {
				my $ipaddr = $row2->{'ipaddr'};
				my $cmac = $row2->{'mac'};
				my $ownerid = $row2->{'ownerid'};
				my $ipaddr32=$ipaddr."/32";
				my $name_kolejka = $row2->{'name'};
				# budujemy opis, je¶li zaczyna siê od prefixu LMS, to jest dodane przez skrypt
				my $name = $aclprefix.':uid'.$ownerid.':nid'.$row2->{'id'}.':'.$row2->{'name'};
				my $taryfa = taryfy($ownerid,$ipaddr);
				# ustawiamy domy¶ln± predko¶æ, nawet jak kto¶ nie ma taryfy, aby wy¶wietla³y siê strony serwisowe
				my $down=$def_down;
				my $up=$def_up;
				my $dbq3 = $dbase->prepare("SELECT uprate, downrate, upceil, downceil FROM tariffs WHERE id=$taryfa");
				$dbq3->execute();
				while (my $row3 = $dbq3->fetchrow_hashref()) {
					$down = $row3->{'downceil'} * $tariff_mult;
					$up = $row3->{'upceil'} * $tariff_mult;
				}
				my $max_limit= $up."k/".$down."k";
				if (!$quiet and $acl_enable) { print STDERR "$cmac @ $iface <-> "; }

				# szukamy czy mamy ju¿ zarejestrowany komputer na MT
				my $zarejestrowany = 0 ;
#				if ($acl_enable) {
#				    foreach my $id (keys (%wireless_macs)) {
#					if ( ($wireless_macs{$id}{'mac-address'} eq $cmac ) and ( $wireless_macs{$id}{'interface'} eq $iface) ) {
#						if (!$quiet) { print STDERR "acl istnieje -> "; }
#						$zarejestrowany=1;
#						my $poprawic_wpis=0;
#						my %attrs4;
#						# je¶li ju¿ dodany, to trzeba sprawdziæ wszystkie atrybuty i ewentualnie poprawiæ
#						# maca i interfejsu nie sprawdzamy bo zrobili¶my to wcze¶niej
#						if ( $wireless_macs{$id}{'private-algo'} ne $macs_private_algo )                     { $wireless_macs{$id}{'private-algo'}=$macs_private_algo;                      $poprawic_wpis+= 1;   $attrs4{'private-algo'}=$macs_private_algo; }
#						if ( $wireless_macs{$id}{'disabled'} ne $macs_disabled )                             { $wireless_macs{$id}{'disabled'}=$macs_disabled ;                             $poprawic_wpis+= 2;   $attrs4{'disabled'}=$macs_disabled; }
#						if ( $wireless_macs{$id}{'forwarding'} ne $macs_forwarding )                         { $wireless_macs{$id}{'forwarding'}=$macs_forwarding ;                         $poprawic_wpis+= 4;   $attrs4{'forwarding'}=$macs_forwarding; }
#						if ( $wireless_macs{$id}{'authentication'} ne $macs_authentication )                 { $wireless_macs{$id}{'authentication'}=$macs_authentication ;                 $poprawic_wpis+= 8;   $attrs4{'authentication'}=$macs_authentication; }
#						if ( $wireless_macs{$id}{'client-tx-limit'} ne $macs_client_tx_limit )               { $wireless_macs{$id}{'client-tx-limit'}=$macs_client_tx_limit;                $poprawic_wpis+= 16;  $attrs4{'client-tx-limit'}=$macs_client_tx_limit; }
#						if ( $wireless_macs{$id}{'ap-tx-limit'} ne $macs_ap_tx_limit )                       { $wireless_macs{$id}{'ap-tx-limit'}=$macs_ap_tx_limit;                        $poprawic_wpis+= 32;  $attrs4{'ap-tx-limit'}=$macs_ap_tx_limit; }
#						if ( $wireless_macs{$id}{'signal-range'} ne $macs_signal_range )                     { $wireless_macs{$id}{'signal-range'}=$macs_signal_range;                      $poprawic_wpis+= 64;  $attrs4{'signal-range'}=$macs_signal_range; }
#						if ( $wireless_macs{$id}{'private-pre-shared-key'} ne $macs_private_pre_shared_key ) { $wireless_macs{$id}{'private-pre-shared-key'}=$macs_private_pre_shared_key ; $poprawic_wpis+= 128; $attrs4{'private-pre-shared-key'}=$macs_private_pre_shared_key; }
#						if ( $wireless_macs{$id}{'private-key'} ne $macs_private_key )                       { $wireless_macs{$id}{'private-key'}=$macs_private_key;                        $poprawic_wpis+= 256; $attrs4{'private-key'}=$macs_private_key; }
#						if ( $wireless_macs{$id}{'comment'} ne $name )                                       { $wireless_macs{$id}{'comment'}=$name;                                        $poprawic_wpis+= 512; $attrs4{'comment'}=$name; }
#						if ( $poprawic_wpis and $wireless_macs{$id}{'LMS'} < 2 ) {
#							if (!$quiet) { print STDERR "acl jest do poprawy ($poprawic_wpis) -> "; }
#							$attrs4{'.id'} = $id;
#							my($retval4,@results4)=Mtik::mtik_cmd('/interface/wireless/access-list/set',\%attrs4);
#							sleep ($api_delay);
#							print STDERR "ret: $retval4 -> ";
#							if ($retval4 != 1) {
#								print STDERR "BLAD przy zmianie acl! || "; }
#							else { if (!$quiet) { print STDERR "OK(set_acl) || "; } }
#						}
#						else { if (!$quiet) { print STDERR "OK || "; } }
#						$wireless_macs{$id}{'LMS'} = 1;
#					} # end of if ( ($wireless_macs{$id}{'mac-address'} eq $cmac ) and ( $wireless_macs{$id}{'interface'} eq $iface) ) {
#				    } # end of foreach my $id (keys (%wireless_macs)) {
#				} #end of if ($acl_enable) {
#
#				if (!$zarejestrowany and $acl_enable) {
#					print STDERR "brak acl -> ";
#					my %attrs2; $attrs2{'mac-address'}=$cmac; $attrs2{'comment'}=$name; $attrs2{'disabled'}=$macs_disabled; $attrs2{'ap-tx-limit'}=$macs_ap_tx_limit; $attrs2{'authentication'}=$macs_authentication; $attrs2{'client-tx-limit'}=$macs_client_tx_limit; $attrs2{'forwarding'}=$macs_forwarding; $attrs2{'interface'}=$iface; $attrs2{'private-algo'}=$macs_private_algo; $attrs2{'private-key'}=$macs_private_key; $attrs2{'private-pre-shared-key'}=$macs_private_pre_shared_key; $attrs2{'signal-range'}=$macs_signal_range;
#					my($retval2,@results2)=Mtik::mtik_cmd('/interface/wireless/access-list/add',\%attrs2);
#					sleep ($api_delay);
#					print STDERR "ret: $retval2 -> ";
#					if ($retval2 < 2) {
#						if (!$quiet) { print STDERR "OK(add_acl) || "; }
#					}
#					else { print "BLAD!(add_acl) || "; }
#				}



				my $dopisany = 0;
#				if ($dhcp_enable) {
#                                    my $poprawic_wpis_dhcp=0;
#                                    # teraz musimy sprawdzic lease z dhcp-server
#                                    # jesli mamy taki wpis, to porównujemy wartosci
#				    foreach my $id (keys (%wireless_dhcp)) {
#                                        if ( $wireless_dhcp{$id}{'mac-address'} eq $cmac ) {
#                                                if (!$quiet) { print STDERR "dhcp istnieje -> "; }
#                                                $dopisany=1;
#                                                my $poprawic_wpis_dhcp=0;
#                                                my %attrs8;
#                                                # je¶li ju¿ dodany, to trzeba sprawdziæ wszystkie atrybuty i ewentualnie poprawiæ
#                                                if ( $wireless_dhcp{$id}{'address'} ne $ipaddr )	{ $wireless_dhcp{$id}{'address'}=$ipaddr;	$poprawic_wpis_dhcp+= 1;	$attrs8{'address'}=$ipaddr; }
#						if ( $wireless_dhcp{$id}{'server'} ne $key )		{ $wireless_dhcp{$id}{'server'}=$key;		$poprawic_wpis_dhcp+= 2;	$attrs8{'server'}=$key; }
#						if ( $wireless_dhcp{$id}{'comment'} ne $name )		{ $wireless_dhcp{$id}{'comment'}=$name;		$poprawic_wpis_dhcp+= 4;	$attrs8{'comment'}=$name; }
#                                                if ( $poprawic_wpis_dhcp and $wireless_dhcp{$id}{'LMS'} < 2 ) {
#                                                        if (!$quiet) { print STDERR "dhcp jest do poprawy ($poprawic_wpis_dhcp) -> "; }
#                                                        $attrs8{'.id'} = $id;
#                                                        my($retval8,@results8)=Mtik::mtik_cmd('/ip/dhcp-server/lease/set',\%attrs8);
#                                                        sleep ($api_delay);
#                                                        print STDERR "ret: $retval8 -> ";
#                                                        if ($retval8 != 1) {
#                                                                print STDERR "BLAD przy zmianie wpisu dhcp! || "; }
#                                                        else { if (!$quiet) { print STDERR "OK(set_dhcp) || "; } }
#                                                }
#                                                else { if (!$quiet) { print STDERR "OK || "; } }
#                                                $wireless_dhcp{$id}{'LMS'} = 1;
#                                        } # end of if ( ($wireless_macs{$id}{'mac-address'} eq $cmac ) and ( $wireless_macs{$id}{'interface'} eq $iface) ) {
#                                    } # end of foreach my $id (keys (%wireless_macs)) {
#				    }

				    if (!$dopisany and $dhcp_enable) {
                                        print STDERR "brak dhcp, dodaje -> ";
					my %attrs7; $attrs7{'address'} = $ipaddr; $attrs7{'mac-address'} = $cmac; $attrs7{'server'} = $key; $attrs7{'comment'} = $name;
#					my($retval7,@results7)=Mtik::mtik_cmd('/ip/dhcp-server/lease/add',\%attrs7);
#/ip dhcp-server lease add address=$attrs7{'address'} mac-address=$attrs7{'mac-address'}
#/ip dhcp-server lease add address=$attrs7{'address'} mac-address=$attrs7{'mac-address'} comment=$attrs7{'comment'}
my($retval7,@results7)=`ssh -l admin-ssh -i ./mt-test 192.168.44.2 "
/ip dhcp-server lease add address=$attrs7{'address'} mac-address=$attrs7{'mac-address'} comment=$attrs7{'comment'}
"`;
#my($retval7,@results7)=`ssh -l admin-ssh -i ./mt-test 192.168.44.2 "
#/ip dhcp-server lease add address=$attrs7{'address'} mac-address=$attrs7{'mac-address'} server=$attrs7{'server'} comment=$attrs7{'comment'}
#"`;
                                        sleep ($api_delay);
                                        print STDERR "ret: $retval7 -> ";
#                                        if ($retval7 != 1) {
                                        if ($retval7) {
                                                print "BLAD przy dodawaniu wpisu dhcp! || \n"; }
                                        else { if (!$quiet) { print STDERR "OK(add_dhcp) || \n"; } }
                                	}

				

				if ($queue_enable) {
				    my $poprawic_wpis_simple=0;
				    # teraz musimy sprawdziæ kolejkê simple
				    # jesli mamy taki wpis, to porównujemy warto¶ci
				    # print STDERR ":1:$name_kolejka:2:$wireless_queues{$name_kolejka}{'name'}:3:";
				    if ( defined ($wireless_queues{$name_kolejka}{'name'}) ) {
					if (!$quiet) { print STDERR "queue istnieje -> "; }
					my %attrs5;
					if ( $wireless_queues{$name_kolejka}{'max-limit'} ne $max_limit )        { $wireless_queues{$name_kolejka}{'max-limit'}=$max_limit;        $poprawic_wpis_simple+= 1;  $attrs5{'max-limit'} = $max_limit; }
					if ( $wireless_queues{$name_kolejka}{'target-addresses'} ne $ipaddr32 )  { $wireless_queues{$name_kolejka}{'target-addresses'}=$ipaddr32;  $poprawic_wpis_simple+= 2;  $attrs5{'target-addresses'} = $ipaddr32; }
					if ( $wireless_queues{$name_kolejka}{'interface'} ne $simple_interface ) { $wireless_queues{$name_kolejka}{'interface'}=$simple_interface; $poprawic_wpis_simple+= 4;  $attrs5{'interface'} = $simple_interface; }
					if ( $wireless_queues{$name_kolejka}{'time'} ne $simple_time )           { $wireless_queues{$name_kolejka}{'time'}=$simple_time;           $poprawic_wpis_simple+= 8;  $attrs5{'time'} = $simple_time; }
					if ( $poprawic_wpis_simple ) {
						if (!$quiet) { print STDERR "queue jest do poprawy ($poprawic_wpis_simple): "; }
				    		    $attrs5{'.id'}=$wireless_queues{$name_kolejka}{'.id'};
						    my($retval5,@results5)=Mtik::mtik_cmd('/queue/simple/set',\%attrs5);
						    Mtik::mtik_cmd('/ip/dhcp-server/lease/add address=192.168.65.21 mac-address=00:00:00:11:11:11');
						    sleep ($api_delay);
						    if ($retval5 != 1) {
							print STDERR "BLAD przy zmianie wpisu queue!\n"; }
						    else { if (!$quiet) { print STDERR "OK(set_queue)\n"; } }
					}
					$wireless_queues{$name_kolejka}{'LMS'} = 1; 
				    }
				    else {
					print STDERR "dodawanie queue -> ";
					my %attrs1; $attrs1{'name'} = $name_kolejka; $attrs1{'target-addresses'} = $ipaddr; $attrs1{'max-limit'} = $max_limit; $attrs1{'burst-limit'} = $simple_burst_limit; $attrs1{'burst-threshold'} = $simple_burst_threshold; $attrs1{'burst-time'} = $simple_burst_time; 
					# $attrs1{'disable'} = $simple_disable;
					$attrs1{'direction'} = $simple_direction; $attrs1{'dst-address'} = $simple_dst_address; $attrs1{'interface'} = $simple_interface; $attrs1{'limit-at'} = $simple_limit_at; $attrs1{'parent'} = $simple_parent; $attrs1{'priority'} = $simple_priority; $attrs1{'queue'} = $simple_queue; $attrs1{'time'} = $simple_time;  $attrs1{'total-queue'} = $simple_total_queue;
					my($retval1,@results1)=Mtik::mtik_cmd('/queue/simple/add',\%attrs1);
					sleep ($api_delay);
					print STDERR "ret: $retval1 -> ";
					if ($retval1 != 1) {
						print "BLAD przy dodawaniu queue!\n"; }
					else { if (!$quiet) { print STDERR "OK(add_queue)\n"; } }
				    }
				{ if (!$quiet) { print STDERR "OK \n"; } }
				} # end of if ($queue_enable) {
			} # end of if(matchip($row2->{'ipaddr'},$row->{'address'},$row->{'mask'})) {
		} # end of while (my $row2 = $dbq2->fetchrow_hashref()) {

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
                        if (( $wireless_dhcp{$id}{'server'} eq $key) and ($wireless_dhcp{$id}{'LMS'} < 1 )) {
                                print STDERR "usuwam zbedne $wireless_dhcp{$id}{'mac-address'} @ $wireless_dhcp{$id}{'server'} -> ";
                                my %attrs9; $attrs9{'.id'}=$wireless_dhcp{$id}{'.id'};
                                my($retval9,@results9)=Mtik::mtik_cmd('/ip/dhcp-server/lease/remove',\%attrs9);
                                sleep ($api_delay);
                                print STDERR "ret: $retval9 -> ";
                                if ($retval9 == 1) {
                                        if (!$quiet) { print STDERR "OK!(del_dhcp) || ";} }
                                else { print "BLAD!(del_dhcp)\n"; }
                        }
                    }
                }

	} # end of while (my $row = $dbq->fetchrow_hashref()) {
} # end of foreach my $key (@networks) {

# usuwamy kolejki które nie maj± powiazania
if ($queue_enable) {
    foreach my $name_queues (keys (%wireless_queues)) {
	# wykonujemy tylko raz na koniec
	if ($wireless_queues{$name_queues}{'LMS'} < 1 ) {
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





				Mtik::logout;
			} # end of if (Mtik::login($mkhost,$mkuser,$mkpass)) {
				else { print STDERR "Blad polaczenia!\n"; }
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
	# najpierw pobieramy w naturalny sposób aktywn± taryfê
	my $dbq1 = $dbase->prepare("SELECT tariffid FROM assignments WHERE customerid = $user_id AND (datefrom <= $currtime OR datefrom = 0) AND (dateto > $currtime OR dateto = 0) AND suspended = 0");
	$dbq1->execute();
	while (my $row1 = $dbq1->fetchrow_hashref()) {
		$tariff_id = $row1->{'tariffid'};
		my $dbq2 = $dbase->prepare("SELECT id, downceil  FROM tariffs WHERE id = $row1->{'tariffid'} AND downceil <> 0");
		$dbq2->execute();
		while ( my $row2 = $dbq2->fetchrow_hashref()) {
			# szukamy najwiêkszej taryfy
			if ( $row2->{'downceil'} > $max_down ) {
				$max_down = $row2->{'downceil'};
				$max_id = $row2->{'id'};
			}
		}
	}
	# je¶li zosta³a jaka¶ taryfa z id > 0 to zwróc i zakoñcz
	if($max_id > 0 ) {
		return $max_id;
	}

	# nie znaleziono aktywnej taryfy wiec szukam jeszcze nie rozpoczêtych
	$dbq1 = $dbase->prepare("SELECT tariffid FROM assignments WHERE customerid = $user_id AND suspended = 0");
	$dbq1->execute();
	while (my $row1 = $dbq1->fetchrow_hashref()) {
		$tariff_id = $row1->{'tariffid'};
		my $dbq2 = $dbase->prepare("SELECT id, downceil  FROM tariffs WHERE id = $row1->{'tariffid'}");
		$dbq2->execute();
		while ( my $row2 = $dbq2->fetchrow_hashref()) {
			# szukamy najwiêkszej taryfy
			if ( $row2->{'downceil'} > $max_down ) {
				$max_down = $row2->{'downceil'};
				$max_id = $row2->{'id'};
			}
		}
	}
	# je¶li zosta³a jaka¶ taryfa z id > 0 to zwróc i zakoñcz
	if($max_id > 0 ) {
		return $max_id;
	}

	# ostatnia deska ratunku - taryfa zawieszona
	$dbq1 = $dbase->prepare("SELECT tariffid FROM assignments WHERE customerid = $user_id");
	$dbq1->execute();
	while (my $row1 = $dbq1->fetchrow_hashref()) {
		$tariff_id = $row1->{'tariffid'};
		my $dbq2 = $dbase->prepare("SELECT id, downceil  FROM tariffs WHERE id = $row1->{'tariffid'}");
		$dbq2->execute();
		while ( my $row2 = $dbq2->fetchrow_hashref()) {
			# szukamy najwiêkszej taryfy
			if ( $row2->{'downceil'} > $max_down ) {
				$max_down = $row2->{'downceil'};
				$max_id = $row2->{'id'};
			}
		}
	}
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
	my $utsfmt = "UNIX_TIMESTAMP()";
	my $dbq1 = $dbase->prepare("SELECT name, lastreload, reload FROM hosts WHERE name LIKE UPPER('$hostname')");
	$dbq1->execute();
	while ( my $row1 = $dbq1->fetchrow_hashref()) {
		if ( $row1->{'reload'} eq 0 ) {
			return 0;
		}
		else {
			my $sdbq = $dbase->prepare("UPDATE hosts SET reload=0, lastreload=$utsfmt  WHERE name LIKE UPPER('$hostname') and reload=1");
			$sdbq->execute() || die $sdbq->errstr;
			return 1;
		}
	}
}
