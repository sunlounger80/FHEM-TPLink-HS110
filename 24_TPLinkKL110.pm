################################################################
# $Id: 24_TPLinkKL110.pm 21645 2020-04-12 09:11:23Z vk $
#
#  Release 2020-04-12
#
#  Copyright notice
#
#  (c) 2016 Copyright: Volker Kettenbach
#  e-mail: volker at kettenbach minus it dot de
#
#  Description:
#  This is an FHEM-Module for the TP Link TPLinkKL110 
#  wifi controlled power outlet.
#  It support switching on and of the outlet as well as switching
#  on and of the nightmode (green led off).
#  It supports reading several readings as well as the
#  realtime power readings of the KL110.
#
#  Requirements
#  	Perl Module: IO::Socket::INET
#  	Perl Module: IO::Socket::Timeout
#  	
#  	In recent debian based distributions IO::Socket::Timeout can
#  	be installed by "apt-get install libio-socket-timeout-perl"
#  	In older distribution try "cpan IO::Socket::Timeout"
#
#  Origin:
#  https://gitlab.com/volkerkettenbach/FHEM-TPLink-Kasa
#
################################################################

package main;

use strict;
use warnings;
use IO::Socket::INET;
use IO::Socket::Timeout;
use JSON;
use SetExtensions;
use Data::Dumper;


#####################################
sub TPLinkKL110_Initialize($) {
	my ($hash) = @_;

	$hash->{DefFn} = "TPLinkKL110_Define";
	$hash->{ReadFn} = "TPLinkKL110_Get";
	$hash->{SetFn} = "TPLinkKL110_Set";
	$hash->{UndefFn} = "TPLinkKL110_Undefine";
	$hash->{DeleteFn} = "TPLinkKL110_Delete";
	$hash->{AttrFn} = "TPLinkKL110_Attr";
	$hash->{AttrList} = "interval " .
		"disable:0,1 " .
		"nightmode:on,off " .
		"timeout " .
		"$readingFnAttributes";
}

#####################################
sub TPLinkKL110_Define($$) {
	my ($hash, $def) = @_;
	my $name = $hash->{NAME};

	my @a = split("[ \t][ \t]*", $def);
	return "Wrong syntax: use define <name> TPLinkKL110 <hostname/ip> " if (int(@a) != 3);

	$hash->{INTERVAL} = 300;
	$hash->{TIMEOUT} = 1;
	$hash->{HOST} = $a[2];
	$attr{$name}{"disable"} = 0;
	# initial request after 2 secs, there timer is set to interval for further update
	InternalTimer(gettimeofday() + 2, "TPLinkKL110_Get", $hash, 0);

	Log3 $hash, 3, "TPLinkKL110: $name defined.";

	return undef;
}

#####################################
# sends given command and returns ($errmsg/undef,undef/$decrypteddata)
sub TPLinkKL110_SendCommand($$) {
	my ($hash, $command) = @_;
	my $name = $hash->{NAME};

	my $remote_host = $hash->{HOST};
	my $remote_port = 9999;
	my $c = encrypt($command);
	my $socket = IO::Socket::INET->new(PeerAddr => $remote_host,
		PeerPort                                => $remote_port,
		Proto                                   => 'tcp',
		Type                                    => SOCK_STREAM,
		Timeout                                 => $hash->{TIMEOUT})
		or return("Couldn't connect to $remote_host:$remote_port: $@\n", undef);
	$socket->write($c);
	IO::Socket::Timeout->enable_timeouts_on($socket);
	$socket->read_timeout(2.5);

	my $dlen;
	my $res;
	my $errmsg;
	my $data;

	$res = sysread($socket, $dlen, 4);
	$dlen = "" if (!defined($res));

	if ($res != 4) {
		$errmsg = "Could not read 4 length bytes";
	}

	my $datalen = 0;

	if (!defined($errmsg)) {
		for (my $i = 0; $i < 4; $i++) {
			$datalen *= 256;
			$datalen += ord(substr($dlen, $i, 1));
		}

		Log3 $hash, 4, "TPLinkKL110: $name Get length - " . $datalen; # JV


		my $datapart;
		$data = "";
		my $partlen = 0;
		my $remainlen = $datalen;
		my $ctr = 0;

		while (($remainlen > 0) && (!defined($errmsg))) {
			$res = sysread($socket, $datapart, $remainlen);
			if (!defined($res) || $res < 0) {
				$errmsg = "Data reading failed - received errcode: " . $res;
			}
			elsif ($res == 0) {
				$ctr++;
				$errmsg = "Could not read correct length - expected: " . $datalen . "   received: " . $partlen if ($ctr > 2);
			}
			else {
				$ctr = 0;
				$data .= $datapart;
				$remainlen -= $res;
			}
		}

		Log3 $hash, 4, "TPLinkKL110: $name Get read data length - " . length($data); # JV
	}

	$socket->close();

	if (!defined($errmsg)) {
		$data = decrypt($data);
		return(undef, $data);
	}
	else {
		return($errmsg, undef);
	}

}  
  
  
  
#####################################
sub TPLinkKL110_Get($$) {
	my ($hash) = @_;
	my $name = $hash->{NAME};
	my ($success, $json, $realtimejson);
	return "Device disabled in config" if ($attr{$name}{"disable"} eq "1");
	RemoveInternalTimer($hash);
	InternalTimer(gettimeofday() + $hash->{INTERVAL}, "TPLinkKL110_Get", $hash, 1);
	$hash->{NEXTUPDATE} = localtime(gettimeofday() + $hash->{INTERVAL});

	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time);
	$mon++;
	$year += 1900;

	my $errmsg;
	my $data;

	my $command = '{"system":{"get_sysinfo":{}},"time":{"get_time":{}}}';
	($errmsg, $data) = TPLinkKL110_SendCommand($hash, $command);
	if (defined($errmsg)) {
		Log3 $hash, 1, "TPLinkKL110: $name Get failed - " . $errmsg; # JV
		return;
	}

	readingsBeginUpdate($hash);

	($success, $json) = TPLinkKL110__evaljson($name, $data);
	if (!$success) {
		Log3 $hash, 1, "TPLinkKL110: $name Get failed"; # JV
		readingsEndUpdate($hash, 1);
		return;
	}

	Log3 $hash, 3, "TPLinkKL110: $name Get called. Relay state: $json->{'system'}->{'get_sysinfo'}->{'relay_state'}, RSSI: $json->{'system'}->{'get_sysinfo'}->{'rssi'}";

	my $hw_ver = $json->{'system'}->{'get_sysinfo'}->{'hw_ver'};
	my %hwMap = hwMapping();

	foreach my $key (sort keys %{$json->{'system'}->{'get_sysinfo'}}) {
		my $sysinfoValue = $json->{'system'}->{'get_sysinfo'}->{$key};

		#adjust different hw_ver readings 
		if (exists($hwMap{$hw_ver}{'system'}{'get_sysinfo'}{$key})) {
			if (exists($hwMap{$hw_ver}{'system'}{'get_sysinfo'}{$key}{'factor'})) {
				$sysinfoValue = $sysinfoValue * $hwMap{$hw_ver}{'system'}{'get_sysinfo'}{$key}{'factor'};
			}
			$key = $hwMap{$hw_ver}{'system'}{'get_sysinfo'}{$key}{'name'}
		}
				
		# next_action
		if ($key eq "next_action") {
			if ($sysinfoValue->{'type'} eq "1" ) {
				# e.g. 12:34 on
				$sysinfoValue = sprintf("%02i:%02i %s",int($sysinfoValue->{'schd_sec'} / 60 / 60),int($sysinfoValue->{'schd_sec'} / 60 % 60),($sysinfoValue->{'action'} eq "1" ? ' on' : " off" ));
			} else {
				$sysinfoValue = "-None-";
			}
		}
		
		readingsBulkUpdate($hash, $key, $sysinfoValue);
	}
	if ($json->{'system'}->{'get_sysinfo'}->{'relay_state'} == 0) {
		readingsBulkUpdate($hash, "state", "off");
	}
	if ($json->{'system'}->{'get_sysinfo'}->{'relay_state'} == 1) {
		readingsBulkUpdate($hash, "state", "on");
	}
	
	# Get Time
	my $remotetime = $json->{'time'}->{'get_time'}->{'year'}."-";
	$remotetime .= $json->{'time'}->{'get_time'}->{'month'}."-";
	$remotetime .= $json->{'time'}->{'get_time'}->{'mday'}. " ";
	$remotetime .= $json->{'time'}->{'get_time'}->{'hour'}.":";
	$remotetime .= $json->{'time'}->{'get_time'}->{'min'}.":";
	$remotetime .= $json->{'time'}->{'get_time'}->{'sec'};

	readingsBulkUpdate($hash, "time", $remotetime);

	Log3 $hash, 3, "TPLinkKL110: $name Updating readings";
	readingsEndUpdate($hash, 1);
	Log3 $hash, 3, "TPLinkKL110: $name Get end";
}


#####################################
sub TPLinkKL110_Set($$) {
	my ($hash, $name, $cmd, @args) = @_;
	my $cmdList = "on off";
	my ($success, $json, $realtimejson);
	return "\"set $name\" needs at least one argument" unless (defined($cmd));
	return if ($attr{$name}{"disable"} eq "1");
	Log3 $hash, 3, "TPLinkKL110: $name Set <" . $cmd . "> called" if ($cmd !~ /\?/);

	my $command = "";
	if ($cmd eq "on") {
		$command = '{"system":{"on_off":{"state":1}}}';
	}
	elsif ($cmd eq "off") {
		$command = '{"system":{"on_off":{"state":0}}}';
	}
	else # wenn der übergebene Befehl nicht durch X_Set() verarbeitet werden kann, Weitergabe an SetExtensions
	{
		return SetExtensions($hash, $cmdList, $name, $cmd, @args);
	}

	my $errmsg;
	my $data;

	($errmsg, $data) = TPLinkKL110_SendCommand($hash, $command);
	if (defined($errmsg)) {
		Log3 $hash, 1, "TPLinkKL110: $name Set failed - " . $errmsg;
		return;
	}

	readingsBeginUpdate($hash);

	($success, $json) = TPLinkKL110__evaljson($name, $data);
	if (!$success) {
		Log3 $hash, 1, "TPLinkKL110: $name Set failed - parsing";
		readingsEndUpdate($hash, 1);
		return;
	}

	if ($json->{'system'}->{'set_relay_state'}->{'err_code'} eq "0") {
		Log3 $hash, 3, "TPLinkKL110: $name Set OK - get status data";
		TPLinkKL110_Get($hash, "");

	}
	else {
		Log3 $hash, 1, "TPLinkKL110: $name Set failed with error code";
		return "Command failed!";
	}
	return undef;
}


#####################################
sub TPLinkKL110_Undefine($$) {
	my ($hash, $arg) = @_;
	my $name = $hash->{NAME};
	RemoveInternalTimer($hash);
	Log3 $hash, 3, "TPLinkKL110: $name undefined.";
	return;
}


#####################################
sub TPLinkKL110_Delete {
	my ($hash, $arg) = @_;
	my $name = $hash->{NAME};
	Log3 $hash, 3, "TPLinkKL110: $name deleted.";
	return undef;
}


#####################################
sub TPLinkKL110_Attr {
	my ($cmd, $name, $aName, $aVal) = @_;
	my $hash = $defs{$name};

	if ($aName eq "interval") {
		if ($cmd eq "set") {
			$hash->{INTERVAL} = $aVal;
		}
		else {
			$hash->{INTERVAL} = 300;
		}
		Log3 $hash, 3, "TPLinkKL110: $name INTERVAL set to " . $hash->{INTERVAL};
	}

	if ($aName eq "timeout") {
		if ($cmd eq "set") {
			$hash->{TIMEOUT} = $aVal;
		}
		else {
			$hash->{TIMEOUT} = 1;
		}
		Log3 $hash, 3, "TPLinkKL110: $name TIMEOUT set to " . $hash->{TIMEOUT};
	}

	if ($aName eq "nightmode") {
		my $command;
		if ($cmd eq "set") {
			$hash->{NIGHTMODE} = $aVal;
			Log3 $hash, 3, "TPLinkKL110: $name Nightmode $aVal.";
			$command = '{"system":{"set_led_off":{"off":1}}}' if ($aVal eq "on");
			$command = '{"system":{"set_led_off":{"off":0}}}' if ($aVal eq "off");
		}
		if ($cmd eq "del") {
			Log3 $hash, 3, "TPLinkKL110: $name Nightmode attribute removed. Nightmode disabled.";
			$command = '{"system":{"set_led_off":{"off":0}}}';
			$hash->{NIGHTMODE} = "off";
		}
		my $remote_host = $hash->{HOST};
		my $remote_port = 9999;
		my $c = encrypt($command);
		my $socket = IO::Socket::INET->new(PeerAddr => $remote_host,
			PeerPort                                => $remote_port,
			Proto                                   => 'tcp',
			Type                                    => SOCK_STREAM,
			Timeout  => $hash->{TIMEOUT} )
			or return "Couldn't connect to $remote_host:$remote_port: $@\n";
		$socket->write($c);
		IO::Socket::Timeout->enable_timeouts_on($socket);
		$socket->read_timeout(.5);
		my $data;
		$data = <$socket>;
		$socket->close();
		$data = decrypt(substr($data, 4));
		my $json;
		eval {
			$json = decode_json($data);
		} or do {
			Log3 $hash, 2, "TPLinkKL110: $name json-decoding failed. Problem decoding getting statistical data";
			return;
		};
	}
	return undef;
}

# Encryption and Decryption of TP-Link Smart Home Protocol
# XOR Autokey Cipher with starting key = 171
# Based on https://www.softscheck.com/en/reverse-engineering-tp-link-hs110/
sub encrypt {
	my $key = 171;
	my @string = split(//, $_[0]);
	my $result = "\0\0\0" . chr(@string);
	foreach (@string) {
		my $a = $key ^ ord($_);
		$key = $a;
		$result .= chr($a);
	}
	return $result;
}

sub decrypt {
	my $key = 171;
	my $result = "";
	my @string = split(//, $_[0]);
	foreach (@string) {
		my $a = $key ^ ord($_);
		$key = ord($_);
		$result .= chr($a);
	}
	return $result;
}

# mapping for different hardware versions
sub hwMapping {
	my %hwMap = ();
	$hwMap{'1.0'}{'system'}{'get_sysinfo'}{'longitude'}{'name'} = 'longitude';
	$hwMap{'1.0'}{'system'}{'get_sysinfo'}{'longitude'}{'factor'} = 1;
	$hwMap{'1.0'}{'system'}{'get_sysinfo'}{'latitude'}{'name'} = 'latitude';
	$hwMap{'1.0'}{'system'}{'get_sysinfo'}{'latitude'}{'factor'} = 1;
	$hwMap{'2.0'}{'system'}{'get_sysinfo'}{'longitude_i'}{'name'} = 'longitude';
	$hwMap{'2.0'}{'system'}{'get_sysinfo'}{'longitude_i'}{'factor'} = 0.0001;
	$hwMap{'2.0'}{'system'}{'get_sysinfo'}{'latitude_i'}{'name'} = 'latitude';
	$hwMap{'2.0'}{'system'}{'get_sysinfo'}{'latitude_i'}{'factor'} = 0.0001;

	$hwMap{'1.0'}{'emeter'}{'get_realtime'}{'power'}{'name'} = 'power';
	$hwMap{'1.0'}{'emeter'}{'get_realtime'}{'power'}{'factor'} = 1;
	$hwMap{'1.0'}{'emeter'}{'get_realtime'}{'voltage'}{'name'} = 'voltage';
	$hwMap{'1.0'}{'emeter'}{'get_realtime'}{'voltage'}{'factor'} = 1;
	$hwMap{'1.0'}{'emeter'}{'get_realtime'}{'current'}{'name'} = 'current';
	$hwMap{'1.0'}{'emeter'}{'get_realtime'}{'current'}{'factor'} = 1;
	$hwMap{'1.0'}{'emeter'}{'get_realtime'}{'total'}{'name'} = 'total';
	$hwMap{'1.0'}{'emeter'}{'get_realtime'}{'total'}{'factor'} = 1;
	$hwMap{'1.0'}{'emeter'}{'get_realtime'}{'err_code'}{'name'} = 'err_code';
	$hwMap{'1.0'}{'emeter'}{'get_realtime'}{'err_code'}{'factor'} = 1;

	$hwMap{'2.0'}{'emeter'}{'get_realtime'}{'power_mw'}{'name'} = 'power';
	$hwMap{'2.0'}{'emeter'}{'get_realtime'}{'power_mw'}{'factor'} = 0.001;
	$hwMap{'2.0'}{'emeter'}{'get_realtime'}{'voltage_mv'}{'name'} = 'voltage';
	$hwMap{'2.0'}{'emeter'}{'get_realtime'}{'voltage_mv'}{'factor'} = 0.001;
	$hwMap{'2.0'}{'emeter'}{'get_realtime'}{'current_ma'}{'name'} = 'current';
	$hwMap{'2.0'}{'emeter'}{'get_realtime'}{'current_ma'}{'factor'} = 0.001;
	$hwMap{'2.0'}{'emeter'}{'get_realtime'}{'total_wh'}{'name'} = 'total';
	$hwMap{'2.0'}{'emeter'}{'get_realtime'}{'total_wh'}{'factor'} = 0.001;
	$hwMap{'2.0'}{'emeter'}{'get_realtime'}{'err_code'}{'name'} = 'err_code';
	$hwMap{'2.0'}{'emeter'}{'get_realtime'}{'err_code'}{'factor'} = 1;

	$hwMap{'4.0'}{'emeter'}{'get_realtime'}{'power_mw'}{'name'} = 'power';
	$hwMap{'4.0'}{'emeter'}{'get_realtime'}{'power_mw'}{'factor'} = 0.001;
	$hwMap{'4.0'}{'emeter'}{'get_realtime'}{'voltage_mv'}{'name'} = 'voltage';
	$hwMap{'4.0'}{'emeter'}{'get_realtime'}{'voltage_mv'}{'factor'} = 0.001;
	$hwMap{'4.0'}{'emeter'}{'get_realtime'}{'current_ma'}{'name'} = 'current';
	$hwMap{'4.0'}{'emeter'}{'get_realtime'}{'current_ma'}{'factor'} = 0.001;
	$hwMap{'4.0'}{'emeter'}{'get_realtime'}{'total_wh'}{'name'} = 'total';
	$hwMap{'4.0'}{'emeter'}{'get_realtime'}{'total_wh'}{'factor'} = 0.001;
	$hwMap{'4.0'}{'emeter'}{'get_realtime'}{'err_code'}{'name'} = 'err_code';
	$hwMap{'4.0'}{'emeter'}{'get_realtime'}{'err_code'}{'factor'} = 1;
	
	return %hwMap;
}

###############################################################################
#   Test ob JSON-String empfangen wurde
sub TPLinkHS110__evaljson($$) {
	my ($name, $data) = @_;
	my $hash = $defs{$name};
	my $json;
	my $success = 1;
	my $jerr = "ok";

	Log3 $name, 5, "$name - Data returned: " . Dumper $data;
	eval {$json = decode_json($data);} or do
	{
		$success = 0;
	};

	if ($@) {
		$jerr = $@;
	};

	readingsBulkUpdate($hash, "decode_json", $jerr);

	if ($success) {
		return($success, $json);
	}
	else {
		return($success, undef);
	}
}

######################################################################################

1;



=pod
=begin html

<a name="TPLinkKL110"></a>
<h3>TPLinkKL110</h3>
<ul>
  <br>

  <a name="TPLinkKL110"></a>
  <b>Define</b>
    <code>define &lt;name&gt; TPLinkKL110 &lt;ip/hostname&gt;</code><br>
    	<br>
	Defines a TP-Link KL110 wifi-controlled light bulb.<br>
  <p>
  <b>Attributs</b>
	<ul>
		<li><b>interval</b>: The interval in seconds, after which FHEM will update the current measurements. Default: 300s</li>
			An update of the measurements is done on each switch (On/Off) as well.
		<p>
		<li><b>timeout</b>:  Timeout in seconds used while communicationg with the outlet. Default: 1s</li>
			<i>Warning:</i>: the timeout of 1s is chosen fairly aggressive. It could lead to errors, if the outlet is not answerings the requests
			within this timeout.<br>
			Please consider, that raising the timeout could mean blocking the whole FHEM during the timeout!
		<p>
		<li><b>disable</b>: The execution of the module is suspended. Default: no.</li>
			<i>Warning: if your outlet is not on or not connected to the wifi network, consider disabling this module
			by the attribute "disable". Otherwise the cyclic update of the outlets measurments will lead to blockings in FHEM.</i>
	</ul>
  <p>
  <b>Requirements</b>
	<ul>
	This module uses the follwing perl-modules:<br><br>
	<li> Perl Module: IO::Socket::INET </li>
	<li> Perl Module: IO::Socket::Timeout </li>
	</ul>

</ul>

=end html

=begin html_DE

<a name="TPLinkKL110"></a>
<h3>TPLinkKL110</h3>
<ul>
  <br>

  <a name="TPLinkKL110"></a>
  <b>Define</b>
    <code>define &lt;name&gt; TPLinkKL110 &lt;ip/hostname&gt;</code><br>
    	<br>
    	Definiert eine TP-Link KL110 fernsteuerbare Glühbirne. <br>
  <p>
  <b>Attribute</b>
	<ul>
		<li><b>interval</b>: Das Intervall in Sekunden, nach dem FHEM die Messwerte aktualisiert. Default: 300s</li>
			Eine Aktualisierung der Messwerte findet auch bei jedem Schaltvorgang statt.
		<p>
		<li><b>timeout</b>:  Der Timeout in Sekunden, der bei der Kommunikation mit der Steckdose verwendet wird. Default: 1s</li>
			<i>Achtung</i>: der Timeout von 1s ist knapp gewählt. Ggf. kann es zu Fehlermeldungen kommen, wenn die Steckdose nicht 
			schnell genug antwortet.<br>
			Bitte beachten Sie aber auch, dass längere Timeouts FHEM für den Zeitraum des Requests blockieren!
		<p>
		<li><b>disable</b>: Die Ausführung des Moduls wird gestoppt. Default: no.</li>
			<i>Achtung: wenn Ihre Steckdose nicht in Betrieb oder über das WLAN erreichbar ist, sollten Sie
			dieses FHEM-Modul per Attribut "disable" abschalten, da sonst beim zyklischen Abruf der Messdaten
			der Steckdose Timeouts auftreten, die FHEM unnötig verlangsamen.</i>
	</ul>
  <p>
  <b>Requirements</b>
	<ul>
	Das Modul benötigt die folgenden Perl-Module:<br><br>
	<li> Perl Module: IO::Socket::INET </li>
	<li> Perl Module: IO::Socket::Timeout </li>
	</ul>

</ul>
=end html_DE

=item summary Support for TPLink KL110 wifi controlled light bulb.

=item summary_DE Support für die TPLink KL110 WLAN Glühbirnen.
