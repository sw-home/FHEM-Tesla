=head1
        49_TeslaCar.pm

# $Id: $

        Version 1.1

=head1 SYNOPSIS
        Tesla Motors Modul for FHEM
        contributed by Stefan Willmeroth 07/2017

        Get started by defining a TeslaConnection and search your cars:
        define teslaconn TeslaConnection
        set teslaconn scanCars

        Use my referral code to get unlimited supercharging for
        your new Tesla: http://ts.la/stefan1473

=head1 DESCRIPTION
        49_TeslaCar handles individual cars defines by
        49_TeslaConnection

=head1 AUTHOR - Stefan Willmeroth
        swi@willmeroth.com (forum.fhem.de)
=cut

package main;

use strict;
use warnings;
use JSON;
use Switch;
require 'HttpUtils.pm';


##############################################
#my $TeslaCar_headers="speed,odometer,soc,est_lat,est_lng,power,shift_state";

my $TeslaCar_headers="speed,odometer,soc,elevation,est_heading,est_lat,est_lng,".
                     "power,shift_state,range,est_range,heading";

my @TeslaCar_ConvertToKM = (
  "speed","odometer","battery_range","est_battery_range","ideal_battery_range"
);

my @TeslaCar_Data_Nodes = (
  "drive_state","vehicle_state","vehicle_config","charge_state","drive_state",
  "climate_state","gui_settings"
);

##############################################
sub TeslaCar_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}     = "TeslaCar_Set";
  $hash->{DefFn}     = "TeslaCar_Define";
  $hash->{GetFn}     = "TeslaCar_Get";
  $hash->{AttrList}  = "updateTimer pollingTimer stateFormat event-on-update-reading event-on-change-reading event-min-interval";
}

###################################
sub TeslaCar_Set($@)
{
  my ($hash, @a) = @_;
  my $rc = undef;
  my $reDOUBLE = '^(\\d+\\.?\\d{0,2})$';
  my $JSON = JSON->new->utf8(0)->allow_nonref;

  my $carId = $hash->{carId};
  my $availableCmds;

  if (Value($hash->{teslaconn}) ne "Connected") {
    $availableCmds = "not logged in";
  } else {
    $availableCmds ="init requestSettings wakeUpCar charge_limit_soc startCharging stopCharging flashLights honkHorn temperature openChargePort startHvacSystem stopHvacSystem startDefrost";
  }

  return "no set value specified" if(int(@a) < 2);
  return $availableCmds if($a[1] eq "?");

  shift @a;
  my $command = shift @a;

  Log3 $hash->{NAME}, 2, "set command: $command";

  if($command eq "wakeUpCar") {
    my $URL = "/api/1/vehicles/$carId/wake_up";
    $rc = TeslaConnection_postrequest($hash,$URL);
  }
  if($command eq "flashLights") {
    my $URL = "/api/1/vehicles/$carId/command/flash_lights";
    $rc = TeslaConnection_postrequest($hash,$URL);
  }
  if($command eq "honkHorn") {
    my $URL = "/api/1/vehicles/$carId/command/honk_horn";
    $rc = TeslaConnection_postrequest($hash,$URL);
  }
  if($command eq "startCharging") {
    my $URL = "/api/1/vehicles/$carId/command/charge_start";
    $rc = TeslaConnection_postrequest($hash,$URL);
  }
  if($command eq "stopCharging") {
    my $URL = "/api/1/vehicles/$carId/command/charge_stop";
    $rc = TeslaConnection_postrequest($hash,$URL);
  }
  if($command eq "startHvacSystem") {
    my $URL = "/api/1/vehicles/$carId/command/auto_conditioning_start";
    $rc = TeslaConnection_postrequest($hash,$URL);
  }
  if($command eq "stopHvacSystem") {
    my $URL = "/api/1/vehicles/$carId/command/auto_conditioning_stop";
    $rc = TeslaConnection_postrequest($hash,$URL);
  }
  if($command eq "startDefrost") {
    my $URL = "/api/1/vehicles/$carId/command/set_preconditioning_max";
    $rc = TeslaConnection_postdatarequest($hash,$URL,"{\"on\": true}");
  }
  if($command eq "charge_limit_soc") {
    my $min = ReadingsVal($hash->{NAME},"charge_limit_soc_min",50);
    my $max = ReadingsVal($hash->{NAME},"charge_limit_soc_max",100);
    return "Need the new charge limit percentage as numeric argument ($min-$max)"
          if(int(@a) < 1 || $a[0]<$min || $a[0]>$max );
    $rc = TeslaConnection_setChargeLimit($hash,$a[0]);
  }
  if($command eq "temperature") {
    my $min = ReadingsVal($hash->{NAME},"min_avail_temp",15);
    my $max = ReadingsVal($hash->{NAME},"max_avail_temp",28);
    return "Need the new temperature as numeric argument ($min-$max)"
          if(int(@a) < 1 || $a[0]<$min || $a[0]>$max);
    $rc = TeslaConnection_setTemperature($hash,$a[0]);
  }
  if($command eq "openChargePort") {
    my $URL = "/api/1/vehicles/$carId/command/charge_port_door_open";
    $rc = TeslaConnection_postdatarequest($hash,$URL);
  }
  ## Connect event channel, update status
  if($command eq "init") {
    return TeslaCar_Init($hash);
  }
  ## Request Car settings
  if($command eq "requestSettings") {
    TeslaCar_UpdateStatus($hash);
  }
  return $rc;
}

#####################################
sub TeslaCar_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  my $u = "wrong syntax: define <dev-name> TeslaCar <conn-name> <vin> to add a new car";

  return $u if(int(@a) < 4);

  $hash->{teslaconn} = $a[2];
  $hash->{vin} = $a[3];

  #### Delay init if not yet connected
  return undef if(Value($hash->{teslaconn}) ne "Connected");

  my $err = TeslaCar_Init($hash);

  #### Some first time setup stuff
  $attr{$hash->{NAME}}{alias} = $hash->{aliasname} if (!defined $attr{$hash->{NAME}}{alias} && defined $hash->{aliasname});
  $attr{$hash->{NAME}}{pollingTimer} = "60" if (!defined $attr{$hash->{NAME}}{pollingTimer});
  $attr{$hash->{NAME}}{updateTimer} = "600" if (!defined $attr{$hash->{NAME}}{updateTimer});

  Log3 $hash->{NAME}, 2, "$hash->{NAME} defined as TeslaCar $hash->{vin}" if !defined($err);
  return $err;
}

#####################################
sub TeslaCar_Init($)
{
  my ($hash) = @_;

  my $err = TeslaCar_UpdateStatus($hash);

  if (!defined($err)) {
      RemoveInternalTimer($hash);
      TeslaCar_Timer($hash);
  }
  return $err;
}

#####################################
sub TeslaConnection_setChargeLimit($$)
{
  my ($hash, $chargeLimit) = @_;
  my $carId = $hash->{carId};

  my $URL = "/api/1/vehicles/$carId/command/set_charge_limit";
  my $rc = TeslaConnection_postdatarequest($hash,$URL,
    "{\"percent\": $chargeLimit}");
  return $rc;
}

#####################################
sub TeslaConnection_setTemperature($$)
{
  my ($hash, $temperature) = @_;
  my $carId = $hash->{carId};

  my $URL = "/api/1/vehicles/$carId/command/set_temps";
  my $rc = TeslaConnection_postdatarequest($hash,$URL,
    "{\"driver_temp\": $temperature, \"passenger_temp\": $temperature}");
  return $rc;
}

#####################################
sub TeslaCar_Undef($$)
{
   my ( $hash, $arg ) = @_;

   RemoveInternalTimer($hash);
   Log3 $hash->{NAME}, 3, "--- removed ---";
   return undef;
}

#####################################
sub TeslaCar_Get($@)
{
  my ($hash, @args) = @_;

  return "TeslaCar_Get not supported";
}

#####################################
sub TeslaCar_Timer
{
  my ($hash) = @_;
  my $name   = $hash->{NAME};

  my $pollingTimer   = AttrVal($name, "pollingTimer", 60);

    TeslaCar_UpdateStatus($hash);
    
    InternalTimer( gettimeofday() + $pollingTimer, "TeslaCar_Timer", $hash, 0);
}

#####################################
sub TeslaCar_UpdateStatus($)
{
  my ($hash) = @_;
  my $name   = $hash->{NAME};
  my $pollingTimer   = AttrVal($name, "pollingTimer", 60);
  my $updateTimer    = AttrVal($name, "updateTimer", 600);

  my $JSON = JSON->new->utf8(0)->allow_nonref;

  #### Read list of cars, find my carId
  my $URL = "/api/1/vehicles";

  my $carJson = TeslaConnection_request($hash,$URL);
  if (!defined $carJson || $carJson eq "") {
    return "Failed to connect to TeslaCar API, see log for details";
  }

  my $cars = eval {$JSON->decode ($carJson)};
  if($@){
    Log3 $hash->{NAME}, 3, "$hash->{NAME} - JSON error requesting vehicles: $@";
  } else {
    for (my $i = 0; 1; $i++) {
      my $car = $cars->{response}[$i];
      if (!defined $car) { last };
      if ($hash->{vin} eq $car->{vin}) {
#        $hash->{option_codes} = $car->{option_codes};
        $hash->{aliasname}  = $car->{display_name};
        $hash->{carId}      = $car->{id};
        $hash->{vehicle_id} = $car->{vehicle_id};
        $hash->{tokens}     = $car->{tokens};

        my $odometerChangeAge = gettimeofday() - time_str2num(ReadingsTimestamp($name,"odometer",gettimeofday()));
        my $stateChangeAge    = gettimeofday() - time_str2num(ReadingsTimestamp($name,"state",gettimeofday()));

        Log3 $hash->{NAME}, 4, "$hash->{NAME} is $car->{state}, last odometer change: $odometerChangeAge, last state change $stateChangeAge";

        $hash->{skipFull}+=$pollingTimer;

        my $requestFullStatus = (
          $car->{state} eq "online" &&          # request full status at this poll when online and
            (
            $hash->{skipFull} >= $updateTimer ||                   # at least all $updateTimer seconds
              (
              $odometerChangeAge < (3*$pollingTimer) ||                 # or if speed has changed between the last three polls
              $stateChangeAge < (3*$pollingTimer) ||                    # or if state has changed between the last three polls
              ReadingsVal($name,"charging_state","none") eq "Charging"  # or if car is charging
              )
            )
          );

        #### Update State
        if (ReadingsVal($hash->{NAME},"state",undef) ne $car->{state}) {
          readingsBeginUpdate($hash);
          readingsBulkUpdate($hash, "state", $car->{state});
          readingsEndUpdate($hash, 1);
        }

        if ($car->{state} eq "online" && $requestFullStatus) {
          TeslaCar_UpdateVehicleStatus($hash);
          $hash->{skipFull}=0;
        }
        return undef;
      }
    }
    return "Specified car with VIN $hash->{vin} not found";
  }
}

#####################################
sub TeslaCar_UpdateVehicleStatus($)
{
  my ($hash) = @_;
  my $carId = $hash->{carId};
  my $name  = $hash->{NAME};

  my $conn = (defined $hash->{teslaconn}) ? $hash->{teslaconn} : $hash->{NAME};
  my $api_uri = $defs{$conn}->{api_uri};
  my ($gkerror, $token) = getKeyValue($conn."_accessToken");

  #### Get status variables
  my $param = {
    url        => $api_uri . "/api/1/vehicles/$carId/vehicle_data",
    hash       => $hash,
    header     => { "Accept" => "application/json", "Authorization" => "Bearer $token" },
    timeout    => 10,
    callback   => \&TeslaCar_UpdateVehicleCallback
  };

  Log3 $name, 5, "$name request: $param->{url}";

  HttpUtils_NonblockingGet($param);

  return undef;
}

#####################################
sub TeslaCar_UpdateVehicleCallback($)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my %readings = ();
  my $JSON = JSON->new->utf8(0)->allow_nonref;

  if($err ne "") {
    Log3 $name, 2, "error while requesting ".$param->{url}." - $err";
  }
  elsif($data ne "") {
    Log3 $name, 5, "$name returned: $data";

    my $parsed = eval {$JSON->decode ($data)};
    if($@){

      Log3 $hash->{NAME}, 3, "$hash->{NAME} - JSON error requesting data: $@";

    } else {

      foreach my $reading (keys %{$parsed->{response}}) {
        if (grep( /^$reading$/, @TeslaCar_Data_Nodes)) {
          foreach my $subreading (keys %{$parsed->{response}->{$reading}}) {
            $readings{$subreading} = $parsed->{response}->{$reading}->{$subreading};
          }
        }
        else {
          $readings{$reading} = $parsed->{response}->{$reading};
        }
      }

      if (defined $readings{"latitude"} && defined $readings{"longitude"}) {
        $readings{"position"}=$readings{"latitude"} .", ".$readings{"longitude"};
        delete $readings{"latitude"};
        delete $readings{"longitude"};
      }

      if (defined $readings{"timestamp"}) {
        delete $readings{"timestamp"};
      }

      if (defined $readings{"tokens"}) {
        delete $readings{"tokens"};
      }

      foreach my $key ( @TeslaCar_ConvertToKM ) {
        if (defined $readings{$key}) {
          $readings{$key} *= 1.60934;
        }
      }

      if (defined $readings{"speed"}) {
        $readings{"speed"} = 0 + $readings{"speed"};
      }

      if (defined $readings{"software_update"}) {
        foreach my $subreading (keys %{$readings{"software_update"}}) {
          $readings{"update.".$subreading} = $readings{"software_update"}->{$subreading};
        }
        delete $readings{"software_update"};
      }

      #### Update Readings
      readingsBeginUpdate($hash);

      for my $get (keys %readings) {
        my $current = ReadingsVal($hash->{NAME},$get,undef);
        my $setval = defined $readings{$get} ? $readings{$get} :
          (defined $current && looks_like_number($current) ? 0: "");

        readingsBulkUpdate($hash, $get, $readings{$get})
                  if (($get ne "state" && $get ne "odometer") || $current ne $setval);
      }
      readingsEndUpdate($hash, 1);
    }
  }
  return undef;
}

1;

=pod
=begin html

<a name="TeslaCar"></a>
<h3>TeslaCar</h3>
<ul>
  <a name="TeslaCar_define"></a>
  <h4>Define</h4>
  <ul>
    <code>define &lt;name&gt; TeslaCar &lt;connection&gt; &lt;VIN&gt;</code>
    <br/>
    <br/>
    Defines a single TESLA vehicle connected to your account using the VIN (vehicle identification number). <br><br>
    Example:

    <code>define KITT TeslaCar teslaconn 5YJSA7E27HF100000</code><br>

    <br/>
	Typically the TeslaCar devices are created automatically by the scanDevices action in TeslaConnection.
    <br/>
  </ul>

  <a name="TeslaCar_set"></a>
  <b>Set</b>
  <ul>

    <li>wakeUpCar<br>
      If the car is in state 'asleep', it can be put to 'online' using this call
    </li>
    <li>flashLights<br>
      If the car is in state 'online', it will flash its headlights
    </li>
    <li>honkHorn<br>
      If the car is in state 'online', it will honk its horn
    </li>
    <li>startCharging<br>
      If the car is in state 'online' and a charger is attached, it will start charging
    </li>
    <li>stopCharging<br>
      If the car is in state 'online' a charging, it will stop charging
    </li>
    <li>startHvacSystem<br>
      If the car is in state 'online', it will start the air conditioning system
    </li>
    <li>stopHvacSystem<br>
      If the car is in state 'online', it will stop the air conditioning system
    </li>
    <li>startDefrost<br>
      If the car is in state 'online', it will set the climate controls to Max Defrost
    </li>
    <li>charge_limit_soc<br>
      If the car is in state 'online', you can set the charge limit.
      Needs the new charge limit percentage as numeric argument (50-100)
    </li>
    <li>temperature<br>
      If the car is in state 'online', you can set the interior temperature for air conditioning
      Needs the new temperature as numeric argument
    </li>
    <li>openChargePort<br>
      If the car is in state 'online', you can open the charge port or, if attached, unlock the cable
    </li>
    <li>init<br>
      Refresh car connection and details, normally only used internally.
    </li>
  </ul>
  <br>

  <a name="TeslaCar_Attr"></a>
  <h4>Attributes</h4>
  <ul>
    <li><a name="pollingTimer"><code>attr &lt;name&gt; pollingTimer &lt;Integer&gt;</code></a>
                <br />Interval for checking if the car is online, default is 60 seconds</li>
    <li><a name="updateTimer"><code>attr &lt;name&gt; updateTimer &lt;Integer&gt;</code></a>
                <br />Interval for updating car data if it is online but not moving or charging, default is 600 seconds (10 minutes)</li>
  </ul>
</ul>

=end html
=cut
