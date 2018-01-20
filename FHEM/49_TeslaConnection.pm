=head1
        49_TeslaConnection.pm

# $Id: $

        Version 0.9

=head1 SYNOPSIS
        Tesla Motors Modul for FHEM
        contributed by Stefan Willmeroth 07/2017
        
        Get started by defining a TeslaConnection and search your cars: 
        define teslaconn TeslaConnection
        set teslaconn scanCars

        Use my referral code to get unlimited supercharging for 
        your new Tesla: http://ts.la/stefan1473

=head1 DESCRIPTION
        49_TeslaConnection keeps the logon token needed by devices defined by
        49_TeslaCar

=head1 AUTHOR - Stefan Willmeroth
        swi@willmeroth.com (forum.fhem.de)
=cut

package main;

use strict;
use warnings;
use JSON;
use URI::Escape;
use Switch;
use Data::Dumper; #debugging
require 'HttpUtils.pm';

##############################################
sub TeslaConnection_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}        = "TeslaConnection_Set";
  $hash->{DefFn}        = "TeslaConnection_Define";
  $hash->{GetFn}        = "TeslaConnection_Get";
}

###################################
sub TeslaConnection_Set($@)
{
  my ($hash, @a) = @_;
  my $rc = undef;
  my $reDOUBLE = '^(\\d+\\.?\\d{0,2})$';

  my ($gterror, $gotToken) = getKeyValue($hash->{NAME}."_accessToken");

  return "no set value specified" if(int(@a) < 2);
  return "LoginNecessary" if($a[1] eq "?" && !defined($gotToken));
  return "scanCars login logout refreshToken" if($a[1] eq "?");
  if ($a[1] eq "login") {
    return TeslaConnection_GetAuthToken($hash,$a[2],$a[3]);
  }
  if ($a[1] eq "scanCars") {
    TeslaConnection_AutocreateDevices($hash);
  }
  if ($a[1] eq "refreshToken") {
    undef $hash->{expires_at};
    TeslaConnection_RefreshToken($hash);
  }
  if ($a[1] eq "logout") {
    setKeyValue($hash->{NAME}."_accessToken",undef);
    setKeyValue($hash->{NAME}."_refreshToken",undef);
    undef $hash->{expires_at};
    $hash->{STATE} = "Login necessary";
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "state", $hash->{STATE});
    readingsEndUpdate($hash, 1);
  }
}

#####################################
sub TeslaConnection_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  my $u = "wrong syntax: define <conn-name> TeslaConnection [client_id] [redirect_uri] [simulator]";

#  return $u if(int(@a) < 4);

  $hash->{api_uri} = "https://owner-api.teslamotors.com";

#  if(int(@a) >= 4) {
#    $hash->{client_id} = $a[2];
#    $hash->{redirect_uri} = $a[3];
#  }
#  else {
    $hash->{client_id} = "81527cff06843c8634fdc09e8ac0abefb46ac849f38fe1e431c2ef2106796384";
    $hash->{client_secret} = "c7257eb71a564034f9419ee651c7d0e5f7aa6bfbd18bafb5c5c033b093bb2fa3";
#  }

  $hash->{STATE} = "Login necessary";

  # start with a delayed refresh
  setKeyValue($hash->{NAME}."_accessToken",undef);
  InternalTimer(gettimeofday()+10, "TeslaConnection_RefreshToken", $hash, 0);

  return;
}

#####################################
sub TeslaConnection_GetAuthToken
{
  my ($hash,$user,$pwd) = @_;
  my $name = $hash->{NAME};
  my $JSON = JSON->new->utf8(0)->allow_nonref;

  Log3 $name, 4, "Request oauth code for: $user";

  my($err,$data) = HttpUtils_BlockingGet({
    url => "$hash->{api_uri}/oauth/token",
    timeout => 10,
    noshutdown => 1,
    data => {
        grant_type => 'password',
	client_id => $hash->{client_id},
	client_secret => $hash->{client_secret},
	email => $user,
	password => $pwd
    }
  });

  if( $err ) {
    Log3 $name, 2, "$name http request failed: $err";
    return $err;
  } elsif( $data ) {
    Log3 $name, 2, "$name AuthTokenResponse $data";

    $data =~ s/\n//g;
    if( $data !~ m/^{.*}$/m ) {
      Log3 $name, 2, "$name invalid json detected: >>$data<<";
      return "Invalid get token response";
    }
  }

  eval {  
    my $json = $JSON->decode($data);

    if( $json->{error} ) {
      $hash->{lastError} = $json->{error};
    }
  
    setKeyValue($hash->{NAME}."_accessToken",$json->{access_token});
    setKeyValue($hash->{NAME}."_refreshToken", $json->{refresh_token});

    if( $json->{access_token} ) {
      $hash->{STATE} = "Connected";
      readingsBeginUpdate($hash);
      readingsBulkUpdate($hash, "state", $hash->{STATE});

      ($hash->{expires_at}) = gettimeofday();
      $hash->{expires_at} += $json->{expires_in};
      $hash->{username} = $user;

      readingsBulkUpdate($hash, "tokenExpiry", scalar localtime $hash->{expires_at});
      readingsEndUpdate($hash, 1);

      foreach my $key ( keys %defs ) {
        if (($defs{$key}->{TYPE} eq "TeslaCar") && ($defs{$key}->{teslaconn} eq $hash->{NAME})) {
          fhem "set $key init";
        }
      }

      RemoveInternalTimer($hash);
      InternalTimer(gettimeofday()+$json->{expires_in}*3/4,
        "TeslaConnection_RefreshToken", $hash, 0);
      return undef;
    }
  };
  $hash->{STATE} = "Error";
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "state", $hash->{STATE});
  readingsEndUpdate($hash, 1);
}

#####################################
sub TeslaConnection_RefreshToken($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my $conn = $hash->{teslaconn};
  if (!defined $conn) {
    $conn = $hash;
  } else {
    $conn = $defs{$conn};
  }

  my ($gkerror, $refreshToken) = getKeyValue($conn->{NAME}."_refreshToken");
  if (!defined $refreshToken) {
    Log3 $name, 4, "$name: no token to be refreshed";
    return undef;
  }

  if( defined($conn->{expires_at}) ) {
    my ($seconds) = gettimeofday();
    if( $seconds < $conn->{expires_at} - 300 ) {
      Log3 $name, 4, "$name: no token refresh needed";
      return undef
    }
  }

  my ($gterror, $gotToken) = getKeyValue($conn->{NAME}."_accessToken");

  my($err,$data) = HttpUtils_BlockingGet({
    url => "$conn->{api_uri}/oauth/token",
    timeout => 10,
    noshutdown => 1,
    data => {
        grant_type => 'refresh_token',
	client_id => $conn->{client_id},
	client_secret => $conn->{client_secret},
	refresh_token => $refreshToken
    }
  });

  if( $err ) {
    Log3 $name, 2, "$name: http request failed: $err";
  } elsif( $data ) {
    Log3 $name, 4, "$name: RefreshTokenResponse $data";

    $data =~ s/\n//g;
    if( $data !~ m/^{.*}$/m ) {

      Log3 $name, 2, "$name: invalid json detected: >>$data<<";

    } else {

      my $json = decode_json($data);

      if( $json->{error} ) {
        $hash->{lastError} = $json->{error};
      }

      setKeyValue($conn->{NAME}."_accessToken",$json->{access_token});

      if( $json->{access_token} ) {
        $conn->{STATE} = "Connected";
        $conn->{expires_at} = gettimeofday();
        $conn->{expires_at} += $json->{expires_in};
        undef $conn->{refreshFailCount};
        readingsBeginUpdate($conn);
        readingsBulkUpdate($conn, "tokenExpiry", scalar localtime $conn->{expires_at});
        readingsBulkUpdate($conn, "state", $conn->{STATE});
        readingsEndUpdate($conn, 1);
        RemoveInternalTimer($conn);
        InternalTimer(gettimeofday()+$json->{expires_in}*3/4,
          "TeslaConnection_RefreshToken", $conn, 0);
        if (!$gotToken) {
          foreach my $key ( keys %defs ) {
            if ($defs{$key}->{TYPE} eq "TeslaCar") {
              fhem "set $key init";
            }
          }
        }
        return undef;
      }
    }
  }

  $conn->{STATE} = "Refresh Error" ;

  if (defined $conn->{refreshFailCount}) {
    $conn->{refreshFailCount} += 1;
  } else {
    $conn->{refreshFailCount} = 1;
  }

  if ($conn->{refreshFailCount}==10) {
    Log3 $conn->{NAME}, 2, "$conn->{NAME}: Refreshing token failed too many times, stopping";
    $conn->{STATE} = "Login necessary";
    setKeyValue($hash->{NAME}."_refreshToken", undef);
  } else {
    RemoveInternalTimer($conn);
    InternalTimer(gettimeofday()+60, "TeslaConnection_RefreshToken", $conn, 0);
  }

  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "state", $hash->{STATE});
  readingsEndUpdate($hash, 1);
  return undef;
}

#####################################
sub TeslaConnection_AutocreateDevices
{
  my ($hash) = @_;

  #### Read list of appliances
  my $URL = "/api/1/vehicles";

  my $carJson = TeslaConnection_request($hash,$URL);
  if (!defined $carJson) {
    return "Failed to connect to TeslaConnection API, see log for details";
  }

  my $cars = decode_json ($carJson);

  for (my $i = 0; 1; $i++) {
    my $car = $cars->{response}[$i];
    if (!defined $car) { last };
    if (!defined $defs{$car->{vin}}) {
      fhem ("define $car->{vin} TeslaCar $hash->{NAME} $car->{vin}");
    }
  }

  return undef;
}

#####################################
sub TeslaConnection_Undef($$)
{
   my ( $hash, $arg ) = @_;

   RemoveInternalTimer($hash);
   Log3 $hash->{NAME}, 3, "--- removed ---";
   return undef;
}

#####################################
sub TeslaConnection_Get($@)
{
  my ($hash, @args) = @_;

  return 'TeslaConnection_Get needs two arguments' if (@args != 2);

  my $get = $args[1];
  my $val = $hash->{Invalid};

  return "TeslaConnection_Get: no such reading: $get";

}

#####################################
sub TeslaConnection_request
{
  my ($hash, $URL) = @_;
  my $name = $hash->{NAME};

  my $api_uri = (defined $hash->{teslaconn}) ? $defs{$hash->{teslaconn}}->{api_uri} : $hash->{api_uri};

  $URL = $api_uri . $URL;

  Log3 $name, 4, "$name request: $URL";

  TeslaConnection_RefreshToken($hash);

  my $conn = $hash->{teslaconn};
  if (!defined $conn) {
    $conn = $name;
  }
  my ($gkerror, $token) = getKeyValue($conn."_accessToken");

  my $param = {
    url        => $URL,
    hash       => $hash,
    timeout    => 3,
    noshutdown => 1,
    header     => { "Accept" => "application/json", "Authorization" => "Bearer $token" }
  };

  my ($err, $data) = HttpUtils_BlockingGet($param);

  if ($err) {
    Log3 $name, 2, "$name can't get $URL -- " . $err;
    return undef;
  }

  Log3 $name, 4 , "$name response: " . $data;

  return $data;

}

#####################################
sub TeslaConnection_postdatarequest
{
  my ($hash, $URL, $put_data) = @_;
  my $name = $hash->{NAME};

  my $api_uri = (defined $hash->{teslaconn}) ? $defs{$hash->{teslaconn}}->{api_uri} : $hash->{api_uri};

  $URL = $api_uri . $URL;

  Log3 $name, 4, "$name POST request: $URL with data: $put_data";

  TeslaConnection_RefreshToken($hash);

  my $conn = $hash->{teslaconn};
  if (!defined $conn) {
    $conn = $name;
  }
  my ($gkerror, $token) = getKeyValue($conn."_accessToken");

  my $param = {
    url        => $URL,
    method     => "POST",
    hash       => $hash,
    timeout    => 3,
    noshutdown => 1,
    header     => { "Accept" => "application/json",
                    "Authorization" => "Bearer $token",
                    "Content-Type" => "application/json"
                  },
    data       => $put_data
  };

  my ($err, $data) = HttpUtils_BlockingGet($param);

  if ($err) {
    Log3 $name, 1, "$name can't post to $URL -- " . $err;
    return undef;
  }

  Log3 $name, 4, "$name POST response: " . $data;

  return $data;

}

#####################################
sub TeslaConnection_delrequest
{
  my ($hash, $URL) = @_;
  my $name = $hash->{NAME};

  my $api_uri = (defined $hash->{teslaconn}) ? $defs{$hash->{teslaconn}}->{api_uri} : $hash->{api_uri};

  $URL = $api_uri . $URL;

  Log3 $name, 4, "TeslaConnection DELETE request: $URL";

  TeslaConnection_RefreshToken($hash);

  my $conn = $hash->{teslaconn};
  if (!defined $conn) {
    $conn = $name;
  }
  my ($gkerror, $token) = getKeyValue($conn."_accessToken");

  my $param = {
    url        => $URL,
    method     => "DELETE",
    hash       => $hash,
    timeout    => 3,
    noshutdown => 1,
    header     => { "Accept" => "application/json", "Authorization" => "Bearer $token" }
  };

  my ($err, $data) = HttpUtils_BlockingGet($param);

  if ($err) {
    Log3 $name, 1, "$name can't delete $URL -- " . $err;
    return undef;
  }

  Log3 $name, 4, "TeslaConnection DELETE response: " . $data;

  return $data;

}

#####################################
sub TeslaConnection_postrequest
{
  my ($hash, $URL) = @_;
  my $name = $hash->{NAME};

  my $api_uri = (defined $hash->{teslaconn}) ? $defs{$hash->{teslaconn}}->{api_uri} : $hash->{api_uri};

  $URL = $api_uri . $URL;

  Log3 $name, 4, "TeslaConnection POST request: $URL";

  TeslaConnection_RefreshToken($hash);

  my $conn = $hash->{teslaconn};
  if (!defined $conn) {
    $conn = $name;
  }
  my ($gkerror, $token) = getKeyValue($conn."_accessToken");

  my $param = {
    url        => $URL,
    method     => "POST",
    hash       => $hash,
    timeout    => 3,
    noshutdown => 1,
    header     => { "Accept" => "application/json", "Authorization" => "Bearer $token" }
  };

  my ($err, $data) = HttpUtils_BlockingGet($param);

  if ($err) {
    Log3 $name, 1, "$name can't post $URL -- " . $err;
    return undef;
  }

  Log3 $name, 4, "TeslaConnection POST response: " . $data;

  return $data;

}

1;

=pod
=begin html

<a name="TeslaConnection"></a>
<h3>TeslaConnection</h3>
<ul>
  <a name="TeslaConnection_define"></a>
  <h4>Define</h4>
  <ul>
    <code>define &lt;name&gt; TeslaConnection &lt;api_key&gt; &lt;redirect_url&gt; [simulator]</code>
    <br/>
    <br/>
    Defines a connection and login to Tesla.<br>
    <br/>
    The following steps are needed:<br/>
    <ul>
      <li>Define the FHEM TeslaConnection device<br/>
      <code>define teslaconn TeslaConnection</code><br/></li>
      <li>Execute the set login with your tesla account user name and password, e.g. set teslaconn login user pass </li>
      <li>Execute the set scanDevices action to create TeslaCar devices for your vehicles.</li>
    </ul>
  </ul>
  <br/>
  <a name="TeslaConnection_set"></a>
  <b>Set</b>
  <ul>
    <li>scanCars<br/>
      Start a vehicle scan of the Tesla account. The registered cars will then be created as devices automatically
      in FHEM. The device scan can be started several times and will not duplicate cars.
      </li>
    <li>refreshToken<br/>
      Manually refresh the access token. This should be necessary only after internet connection problems.
      </li>
    <li>logout<br/>
      Delete the access token and refresh tokens, and show the login link again.
      </li>
  </ul>
  <br/>

</ul>

=end html
=cut
