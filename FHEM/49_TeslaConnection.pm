=head1
        49_TeslaConnection.pm

# $Id: $

        Version 1.1

=head1 SYNOPSIS
        Tesla Motors Modul for FHEM
        contributed by Stefan Willmeroth 07/2017
        
        Get started by defining a TeslaConnection and search your cars: 
        define teslaconn TeslaConnection
        set teslaconn scanCars

=head1 DESCRIPTION
        49_TeslaConnection keeps the logon token needed by devices defined by
        49_TeslaCar

=head1 AUTHOR - Stefan Willmeroth
        swi@willmeroth.com (forum.fhem.de)
        Forked by Timo Dostal and Jaykoert all credits goes to Stefan Willmeroth & mrmops
        2022-04-17 Oliver Vallant adapted to TESLA's new refresh/accessToken handling
=cut

package main;

use strict;
use warnings;
use HttpUtils;
use JSON;
use URI::Escape;
use Switch;
use Data::Dumper; #debugging


##############################################
sub TeslaConnection_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}        = "TeslaConnection_Set";
  $hash->{DefFn}        = "TeslaConnection_Define";
  $hash->{GetFn}        = "TeslaConnection_Get";
  $hash->{AttrList}     = "RefreshToken";

  $attr{$hash->{NAME}}{RefreshToken} = "NeedsToBeDefined" if (!defined $attr{$hash->{NAME}}{RefreshToken});

}

###################################
sub TeslaConnection_Set($@)
{
  my ($hash, @a) = @_;

  return "no set value specified" if(int(@a) < 2);
  return "scanCars connect disconnect refreshAccessToken" if($a[1] eq "?");
  if ($a[1] eq "connect") {
    TeslaConnection_Connect($hash, $hash->{NAME});
  }
  if ($a[1] eq "scanCars") {
    TeslaConnection_AutocreateDevices($hash);
  }
  if ($a[1] eq "disconnect") {
    TeslaConnection_Disconnect($hash, $hash->{NAME});
  }
  if ($a[1] eq "refreshAccessToken") {
    TeslaConnection_clearAccessToken($hash);
    TeslaConnection_RefreshToken($hash);
  }
}

sub TeslaConnection_Connect {
  my ($hash, $name) = @_;

  $hash->{STATE} = "connected";
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "state", $hash->{STATE});
  readingsEndUpdate($hash, 1);
  Log3 $hash->{NAME}, 4, "$hash->{NAME} Connect to Tesla API" ;
  TeslaConnection_RefreshToken($hash);
}

sub TeslaConnection_Disconnect {
  my ($hash, $name) = @_;

  $hash->{STATE} = "disconnected";
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "state", $hash->{STATE});
  readingsEndUpdate($hash, 1);
  Log3 $hash->{NAME}, 4, "$hash->{NAME} Disconnect from Tesla API" ;
}

#####################################
sub TeslaConnection_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);
  my $name   = $a[0];

  my $u = "wrong syntax: define <conn-name> TeslaConnection";

  $hash->{api_uri}   = "https://owner-api.teslamotors.com";
  $hash->{auth_uri}  = "https://auth.tesla.com/oauth2/v3/token";
  $hash->{client_id} = "ownerapi";
  $hash->{STATE}     = "Login necessary";

  # start with a delayed refresh
  TeslaConnection_clearAccessToken($hash);
  InternalTimer(gettimeofday()+10, "TeslaConnection_Connect", $hash, 0);

  return;
}

#####################################
sub TeslaConnection_RefreshToken($)
{
  my ($hash) = @_;
  my $conn = $hash->{teslaconn};
  if (!defined $conn) {
    $conn = $hash;
  }
  else {
    $conn = $defs{$conn};

  }
  my $name = $conn->{NAME};

  my $refreshToken = AttrVal($conn->{NAME}, "RefreshToken", "");
  $refreshToken =~ s/ //g;
  if ($refreshToken eq "") {
    Log3 $name, 4, "$name: no refreshToken to get new accessToken";
    readingsBeginUpdate($conn);
    readingsBulkUpdate($conn, "state", "refreshToken missing");
    readingsEndUpdate($conn, 1);
    return undef;
  } else {
      Log3 $name, 4 , "$name current refreshToken: " . TeslaConnection_TokenInShort($refreshToken);
  }

  if (defined($conn->{expires_at})) {
    if (gettimeofday() < $conn->{expires_at} - 300) {
      Log3 $name, 4, "$name: no token refresh needed";
      return undef
    }
  }

  TeslaConnection_clearAccessToken($hash);

  my $param = {
      url         => "$conn->{auth_uri}",
      timeout     => 10,
      noshutdown  => 1,
      httpversion => "1.1",
      hash        => $conn,
      callback    => \&TeslaConnection_RefreshToken_Callback,
      data        => {
          grant_type    => 'refresh_token',
          client_id     => $conn->{client_id},
          refresh_token => $refreshToken
      }
  };

  HttpUtils_NonblockingGet($param);
}

sub TeslaConnection_RefreshToken_Callback {
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $conn = $hash;

  if( $err ) {
    Log3 $name, 2, "$name: http request failed: $err";
  } elsif( $data ) {
    Log3 $name, 4, "$name: RefreshTokenResponse $data";
    $conn->{last_response} = strftime("%F %X", localtime(gettimeofday()));

    $data =~ s/\n//g;
    if( $data !~ m/^{.*}$/m ) {
      Log3 $name, 2, "$name: invalid json detected: >>$data<<";
    } else {
      my $json = eval {decode_json($data)};
      if($@){
        Log3 $name, 2, "$name JSON error while reading refreshed token";
      } else {

        if( $json->{error} ) {
          Log3 $name, 2, "$name JSON Tesla API reported an error within response: " . $json->{error};
        }

        if( $json->{access_token} ) {
          setKeyValue($conn->{NAME}."_accessToken",  $json->{access_token});
          $conn->{STATE}         = "connected";
          $conn->{expires_at}    = round(gettimeofday() + $json->{expires_in}, 0);
          $conn->{accessToken}   = TeslaConnection_TokenInShort($json->{access_token});
          $conn->{refreshed_at}  = strftime("%F %X", localtime(gettimeofday()));
          undef $conn->{lastError};
          undef $conn->{refreshFailCount};
          readingsBeginUpdate($conn);
          readingsBulkUpdate($conn, "tokenExpiry", strftime("%F %X", localtime($conn->{expires_at})));
          readingsBulkUpdate($conn, "state", $conn->{STATE});
          readingsEndUpdate($conn, 1);
          Log3 $name, 4 , "$name got new accessToken: " . TeslaConnection_TokenInShort($json->{access_token});
          foreach my $key ( keys %defs ) {
            if ($defs{$key}->{TYPE} eq "TeslaCar" && $defs{$key}->{teslaconn} eq $conn->{NAME}) {
              fhem "set $key init";
            }
          }
          return undef;
        }
      }
      }
    }

  
  $conn->{STATE}     = "refreshToken invalid" ;
  $conn->{lastError} = "refreshToken invalid, trying..."; 
  if (defined $conn->{refreshFailCount}) {
    $conn->{refreshFailCount} += 1;
  } else {
    $conn->{refreshFailCount} = 1;
  }


  if ($conn->{refreshFailCount}>=10) {
    Log3 $conn->{NAME}, 2, "$conn->{NAME}: Refreshing token failed too many times, stopping";
    $conn->{STATE} = "disconnected";
    $conn->{lastError} = "refreshToken invalid and stopped after 10 tries.";
    setKeyValue($conn->{NAME}."_accessToken", undef);
  } else {
    RemoveInternalTimer($conn);
    InternalTimer(gettimeofday()+60, "TeslaConnection_RefreshToken", $conn, 0);
  }

  readingsBeginUpdate($conn);
  readingsBulkUpdate($conn, "state", $conn->{STATE});
  readingsEndUpdate($conn, 1);
  return undef;
}

#####################################
sub TeslaConnection_AutocreateDevices
{
  my ($hash) = @_;

  #### Read list of vehicles
  my $URL = "/api/1/vehicles";

  $hash->{dataCallback} = sub {
    my $carJson = shift;

    Log3 $hash->{NAME}, 5, "car scan response $carJson";

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
  };

  Log3 $hash->{NAME}, 3, "start car scan";
  TeslaConnection_request($hash,$URL);

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
  my $conn = $hash->{teslaconn};
  if (!defined $conn) {
    $conn = $hash;
  }
  else {
    $conn = $defs{$conn};
  }
  my $name = $conn->{NAME};
  $URL = $conn->{api_uri} . $URL;

  if ($conn->{STATE} eq "disconnected") {
    Log3 $name, 4, "$name request: disconnected";
    return undef;
  }

  Log3 $name, 4, "$name request: $URL";
  Log3 $name, 5, "$name callback function: $hash->{dataCallback}";

  TeslaConnection_RefreshToken($hash);
  my ($gkerror, $token) = getKeyValue($name."_accessToken");

  if (!$token) {
    Log3 $name, 1, "$name token is undef";
    return undef;
  }
  Log3 $name, 4, "$name request with current accessToken: " . TeslaConnection_TokenInShort($token);

  my $param = {
    url         => $URL,
    hash        => $hash,
    timeout     => 3,
    noshutdown  => 1,
    httpversion => "1.1",
    header      => { "Accept" => "application/json", "Authorization" => "Bearer $token" },
    callback    => \&TeslaConnection_request_callback,
  };

  Log3 $name, 5 , "$name request params: " . Dumper($param) . " Error: ". Dumper($gkerror) . " Token: " . Dumper($token);
  HttpUtils_NonblockingGet($param);
}

sub TeslaConnection_request_callback {
  my ($param, $err, $data) = @_;
  my $name = $param->{hash}->{NAME};

  if ($err) {
    Log3 $name, 2, "$name can't $param->{URL} -- " . $err;
    return undef;
  }

  if ($data ~~ "401 Unauthorized") {
      Log3 $name, 2, "$name authorization at Tesla API failt with current accessToken";
    return undef;
  }

  Log3 $name, 4 , "$name response from Tesla API: " . $data;
  Log3 $name, 5 , "$name params: " . Dumper($param) . " callback function: " . $param->{hash}->{dataCallback};
  
  if ($data && $param->{hash}->{dataCallback}) {
    $param->{hash}->{dataCallback}->($data);
  }
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
    url         => $URL,
    method      => "POST",
    hash        => $hash,
    timeout     => 3,
    noshutdown  => 1,
    header      => { "Accept" => "application/json", "Authorization" => "Bearer $token", "Content-Type" => "application/json" },
    httpversion => "1.1",
    data        => $put_data,
    callback    => \&TeslaConnection_request_callback,
  };

  HttpUtils_NonblockingGet($param);
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
    url         => $URL,
    method      => "DELETE",
    hash        => $hash,
    timeout     => 3,
    noshutdown  => 1,
    httpversion => "1.1",
    header      => { "Accept" => "application/json", "Authorization" => "Bearer $token" },
   callback     => \&TeslaConnection_request_callback,
  };

  HttpUtils_NonblockingGet($param);
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
    url         => $URL,
    method      => "POST",
    hash        => $hash,
    timeout     => 3,
    noshutdown  => 1,
    httpversion => "1.1",
    header      => { "Accept" => "application/json", "Authorization" => "Bearer $token" },
    callback    => \&TeslaConnection_request_callback,
  };

  HttpUtils_NonblockingGet($param);
}

sub TeslaConnection_clearAccessToken($) {
  my ($hash) = @_;

  setKeyValue($hash->{NAME}."_accessToken", undef);
  undef $hash->{expires_at};
  undef $hash->{accessToken};
  undef $hash->{refreshed_at};
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "tokenExpiry", "");
  readingsEndUpdate($hash, 1);
}

sub TeslaConnection_TokenInShort($) {
  my ($token) = @_;
  if (defined $token) {
    return substr($token, 0, 25) . "..." . substr($token, -25, 25);
    } else { return undef; }
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
    <code>define &lt;name&gt; TeslaConnection</code>
    <br/>
    <br/>
    Defines a connection and to the API of Tesla.<br>
    <br/>
    The following steps are needed:<br/>
    <ul>
      <li>Define the FHEM TeslaConnection device<br/>
      <code>define teslaconn TeslaConnection</code><br/></li>
      <li>Add attribute RefreshToken with a token created in a third party app, e.g. "Tesla Token".</li>
      <li>Execute set connect</li>
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
    <li>connect<br/>
      Reads the access token and switches state to connected.
    </li>
    <li>disconnect<br/>
      Delete the access token and refresh tokens.
    </li>
    <li>refreshAccessToken<br/>
      Delete the current accessToken and gets a new one by means of a given refreshTokens.
  </ul>
  <br/>

</ul>

  <a name="TeslaConnection_Attr"></a>
  <h4>Attributes</h4>
  <ul>
        <li><a name="RefreshToken"><code>attr &lt;name&gt; RefreshToken &lt;Token as Text&gt;</code></a>
                <br />RefreshToken will be uesed to request an new AccessToken from the Tesla API.<br>
                You have to created a RefreshToken in a third party app, e.g. Tesla Token and store it here.<br>
                The RefreshToken is only valid for a limited period of time (eg. 6 weeks)<br>
        </li>
     </ul>
</ul>

=end html
=cut

