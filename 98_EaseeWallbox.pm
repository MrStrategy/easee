package main;

use strict;
use warnings;
use Data::Dumper;
use utf8;
use Encode qw( encode_utf8 );
use HttpUtils;
use JSON;

my %EaseeWallbox_gets = (
    update   => "noArg",
    health   => "noArg",
    chargers => "noArg",
    sites    => "noArg",
    profile  => "noArg",
    config   => "noArg",
);

my %EaseeWallbox_sets = (
    startCharging            => "",
    stopCharging             => "",
    pauseCharging            => "",
    resumeCharging           => "",
    toggleCharging           => "",
    interval                 => "",
    refreshToken             => "noArg",
    cableLock                => "true,false",
    reboot                   => "noArg",
    updateFirmware           => "noArg",
    enableSmartCharging      => "true,false",
    overrideChargingSchedule => "",
    pairRfidTag              => "",
    pricePerKWH              => ""
);

my %url = (
    getOAuthToken   => 'https://api.easee.cloud/api/accounts/login',
    getRefreshToken => 'https://api.easee.cloud/api/accounts/refresh_token',
    getProfile      => 'https://api.easee.cloud/api/accounts/profile',
    getChargingSession =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/sessions/ongoing',
    getChargers => 'https://api.easee.cloud/api/accounts/chargers',
    getProducts =>
        'https://api.easee.cloud/api/accounts/products?userId=#UserId#',
    getChargerSite => 'https://api.easee.cloud/api/chargers/#ChargerID#/site',
    getChargerDetails =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/details',
    getChargerConfiguration =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/config',
    getChargerSessionsMonthly =>
        'https://api.easee.cloud/api/sessions/charger/#ChargerID#/monthly',
    getChargerSessionsDaily =>
        'https://api.easee.cloud/api/sessions/charger/#ChargerID#/daily',
    getChargerState =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/state',
    getCurrentSession =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/sessions/ongoing',
    setCableLockState =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/commands/lock_state',
    setReboot =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/commands/reboot',
    setUpdateFirmware =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/commands/update_firmware',
    setEnableSmartCharging =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/commands/smart_charging',
    setStartCharging =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/commands/start_charging',
    setStopCharging =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/commands/stop_charging',
    setPauseCharging =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/commands/pause_charging',
    setResumeCharging =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/commands/resume_charging',
    setToggleCharging =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/commands/toggle_charging',
    setOverrideChargingSchedule =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/commands/override_schedule',
    setPairRFIDTag =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/commands/set_rfid_pairing_mode_async',
    changeChargerSettings =>
        'https://api.easee.cloud/api/chargers/#ChargerID#/settings',
    setChargingPrice => 'https://api.easee.cloud/api/sites/#SiteID#/price',
);

my %reasonForNoCurrent = (
    0 => 'OK',                               #charger is allocated current
    1 => 'MaxCircuitCurrentTooLow',
    2 => 'MaxDynamicCircuitCurrentTooLow',
    3 => 'MaxDynamicOfflineFallbackCircuitCurrentTooLow',
    4 => 'CircuitFuseTooLow',
    5 => 'WaitingInQueue',
    6 => 'WaitingInFully'
    , #charged queue (charger assumes one of: EV uses delayed charging, EV charging complete)
    7   => 'IllegalGridType',
    8   => 'PrimaryUnitHasNotReceivedCurrentRequestFromSecondaryUnit',
    50  => 'SecondaryUnitNotRequestingCurrent',    #no car connected...
    51  => 'MaxChargerCurrentTooLow',
    52  => 'MaxDynamicChargerCurrentTooLow',
    53  => 'ChargerDisabled',
    54  => 'PendingScheduledCharging',
    55  => 'PendingAuthorization',
    56  => 'ChargerInErrorState',
    100 => 'Undefined'
);
my %phaseMode = (
    1 => 'Locked to single phase',
    2 => 'Auto',
    3 => 'Locked to three phase',
);

my %operationMode = (
    1 => "Standby",
    2 => "Paused",
    3 => 'Charging',
    4 => 'Completed',
    5 => 'Error',
    6 => 'CarConnected'
);

#Private function to evaluate command-lists
#############################
sub EaseeWallbox_getCmdList ($$$) {
    my ( $hash, $cmd, $commands ) = @_;

    my %cmdArray = %$commands;
    my $name     = $hash->{NAME};

    #return, if cmd is valid
    return undef if ( defined($cmd) and defined( $cmdArray{$cmd} ) );

    #response for gui or the user, if command is invalid
    my $retVal;
    foreach my $mySet ( keys %cmdArray ) {

        #append set-command
        $retVal = $retVal . " " if ( defined($retVal) );
        $retVal = $retVal . $mySet;

        #get options
        my $myOpt = $cmdArray{$mySet};

        #append option, if valid
        $retVal = $retVal . ":" . $myOpt
            if ( defined($myOpt) and ( length($myOpt) > 0 ) );
        $myOpt = "" if ( !defined($myOpt) );

#Logging makes me crazy...
#Log3 ($name, 5, "parse cmd-table - Set:$mySet, Option:$myOpt, RetVal:$retVal");
    }
    if ( !defined($retVal) ) {
        $retVal = "error while parsing set-table";
    }
    else {
        $retVal = "Unknown argument $cmd, choose one of " . $retVal;
    }
    return $retVal;
}

sub EaseeWallbox_Initialize($) {
    my ($hash) = @_;

    $hash->{DefFn}     = 'EaseeWallbox_Define';
    $hash->{UndefFn}   = 'EaseeWallbox_Undef';
    $hash->{SetFn}     = 'EaseeWallbox_Set';
    $hash->{GetFn}     = 'EaseeWallbox_Get';
    $hash->{AttrFn}    = 'EaseeWallbox_Attr';
    $hash->{ReadFn}    = 'EaseeWallbox_Read';
    $hash->{WriteFn}   = 'EaseeWallbox_Write';
    $hash->{Clients}   = ':EaseeWallbox:';
    $hash->{MatchList} = { '1:EaseeWallbox' => '^EaseeWallbox;.*' };
    $hash->{AttrList}
        = 'expertMode:yes,no '
        . 'ledStuff:yes,no '
        . 'SmartCharging:true,false '
        . $readingFnAttributes;

    Log 3, "EaseeWallbox module initialized.";
}

sub EaseeWallbox_Define($$) {
    my ( $hash, $def ) = @_;
    my @param = split( "[ \t]+", $def );
    my $name  = $hash->{NAME};

    Log3 $name, 3, "EaseeWallbox_Define $name: called ";

    my $errmsg = '';

# Check parameter(s) - Must be min 4 in total (counts strings not purly parameter, interval is optional)
    if ( int(@param) < 4 ) {
        $errmsg = return
            "syntax error: define <name> EaseeWallbox <username> <password> [Interval]";
        Log3 $name, 1, "EaseeWallbox $name: " . $errmsg;
        return $errmsg;
    }

    #Check if the username is an email address
    if ( $param[2] =~ /^.+@.+$/ ) {
        my $username = $param[2];
        $hash->{Username} = $username;
    }
    else {
        $errmsg
            = "specify valid email address within the field username. Format: define <name> EaseeWallbox <username> <password> [interval]";
        Log3 $name, 1, "EaseeWallbox $name: " . $errmsg;
        return $errmsg;
    }

    #Take password and use custom encryption.
    # Encryption is taken from fitbit / withings module
    my $password = EaseeWallbox_encrypt( $param[3] );

    $hash->{Password} = $password;

    if ( defined $param[4] ) {
        $hash->{DEF} = sprintf( "%s %s %s",
            InternalVal( $name, 'Username', undef ),
            $password, $param[4] );
    }
    else {
        $hash->{DEF} = sprintf( "%s %s",
            InternalVal( $name, 'Username', undef ), $password );
    }

    #Check if interval is set and numeric.
    #If not set -> set to 60 seconds
    #If less then 5 seconds set to 5
    #If not an integer abort with failure.
    my $interval = 60;
    if ( defined $param[4] ) {
        if ( $param[4] =~ /^\d+$/ ) {
            $interval = $param[4];
        }
        else {
            $errmsg
                = "Specify valid integer value for interval. Whole numbers > 5 only. Format: define <name> EaseeWallbox <username> <password> [interval]";
            Log3 $name, 1, "EaseeWallbox $name: " . $errmsg;
            return $errmsg;
        }
    }

    if ( $interval < 5 ) { $interval = 5; }
    $hash->{INTERVAL} = $interval;

    readingsSingleUpdate( $hash, 'state', 'Undefined', 0 );

    #Initial load of data
    EaseeWallbox_RefreshData($hash);

    ##RemoveInternalTimer($hash);

#Call getZones with delay of 15 seconds, as all devices need to be loaded before timer triggers.
#Otherwise some error messages are generated due to auto created devices...
    ##InternalTimer(gettimeofday()+15, "EaseeWallbox_GetZones", $hash) if (defined $hash);

    ##Log3 $name, 1, sprintf("EaseeWallbox_Define %s: Starting timer with interval %s", $name, InternalVal($name,'INTERVAL', undef));
    ##InternalTimer(gettimeofday()+ InternalVal($name,'INTERVAL', undef), "EaseeWallbox_UpdateDueToTimer", $hash) if (defined $hash);
    return undef;
}

sub EaseeWallbox_Undef($$) {
    my ( $hash, $arg ) = @_;

    RemoveInternalTimer($hash);
    return undef;
}

sub EaseeWallbox_Get($@) {
    my ( $hash, $name, @args ) = @_;

    return '"get EaseeWallbox" needs at least one argument'
        if ( int(@args) < 1 );

    my $opt = shift @args;

    #create response, if cmd is wrong or gui asks
    my $cmdTemp = EaseeWallbox_getCmdList( $hash, $opt, \%EaseeWallbox_gets );
    return $cmdTemp if ( defined($cmdTemp) );

    my $cmd = $args[0];
    my $arg = $args[1];

    if ( $opt eq "chargers" ) {

        return EaseeWallbox_GetChargers($hash);

    }
    elsif ( $opt eq "profile" ) {

        return EaseeWallbox_RefreshData($hash);

    }
    elsif ( $opt eq "config" ) {

        return EaseeWallbox_GetChargerConfig($hash);

    }
    elsif ( $opt eq "sites" ) {

        return EaseeWallbox_GetChargerSite($hash);

    }
    elsif ( $opt eq "update" ) {

        Log3 $name, 3, "EaseeWallbox_Get $name: Updating all data";
        $hash->{LOCAL} = 1;

        EaseeWallbox_RequestChargerState($hash);
        EaseeWallbox_RequestCurrentSession($hash);

        delete $hash->{LOCAL};
        return undef;

    }
    else {

        my @cList = keys %EaseeWallbox_gets;
        return "Unknown v2 argument $opt, choose one of "
            . join( " ", @cList );
    }
}

sub EaseeWallbox_Set($@) {
    my ( $hash, $name, @param ) = @_;

    return '"set $name" needs at least one argument' if ( int(@param) < 1 );

    my $opt   = shift @param;
    my $value = join( "", @param );

    #create response, if cmd is wrong or gui asks
    my $cmdTemp = EaseeWallbox_getCmdList( $hash, $opt, \%EaseeWallbox_sets );
    return $cmdTemp if ( defined($cmdTemp) );

    if ( $opt eq "startCharging" ) {
        $hash->{LOCAL} = 1;
        EaseeWallbox_ExecuteParameterlessCommand( $hash, "setStartCharging" );
        delete $hash->{LOCAL};
    }
    elsif ( $opt eq 'stopCharging' ) {
        $hash->{LOCAL} = 1;
        EaseeWallbox_ExecuteParameterlessCommand( $hash, "setStopCharging" );
        delete $hash->{LOCAL};

    }
    elsif ( $opt eq 'pauseCharging' ) {
        $hash->{LOCAL} = 1;
        EaseeWallbox_ExecuteParameterlessCommand( $hash, "setPauseCharging" );
        delete $hash->{LOCAL};

    }
    elsif ( $opt eq 'resumeCharging' ) {
        $hash->{LOCAL} = 1;
        EaseeWallbox_ExecuteParameterlessCommand( $hash,
            "setResumeCharging" );
        delete $hash->{LOCAL};

    }
    elsif ( $opt eq 'toggleCharging' ) {
        $hash->{LOCAL} = 1;
        EaseeWallbox_ExecuteParameterlessCommand( $hash,
            "setToggleCharging" );
        delete $hash->{LOCAL};

    }
    elsif ( $opt eq "reboot" ) {
        $hash->{LOCAL} = 1;
        EaseeWallbox_ExecuteParameterlessCommand( $hash, "setReboot" );
        delete $hash->{LOCAL};

    }
    elsif ( $opt eq 'enableSmartCharging' ) {
        $hash->{LOCAL} = 1;
        EaseeWallbox_SetCableLock( $hash, "setEnableSmartCharging" );
        delete $hash->{LOCAL};

    }
    elsif ( $opt eq 'cableLock' ) {
        my $status = shift @param;
        Log3 $name, 3,
            "EaseeWallbox: set $name: processing ($opt), new State: $status";
        EaseeWallbox_SetCableLock( $hash, $status );
        Log3 $name, 3, "EaseeWallbox $name" . ": " . "$opt finished\n";

    }
    elsif ( $opt eq 'pricePerKWH' ) {
        my $price = shift @param;
        Log3 $name, 3,
            "EaseeWallbox: set $name: processing ($opt), new State: $price";
        EaseeWallbox_SetPrice( $hash, $price );
        Log3 $name, 3, "EaseeWallbox $name" . ": " . "$opt finished\n";

    }
    elsif ( $opt eq 'refreshToken' ) {
        Log3 $name, 3, "EaseeWallbox: set $name: processing ($opt)";
        EaseeWallbox_LoadToken($hash);
        Log3 $name, 3, "EaseeWallbox $name" . ": " . "$opt finished\n";
    }

    elsif ( $opt eq "stop" ) {

        RemoveInternalTimer($hash);
        Log3 $name, 1,
            "EaseeWallbox_Set $name: Stopped the timer to automatically update readings";
        readingsSingleUpdate( $hash, 'state', 'Initialized', 0 );
        return undef;

    }
    elsif ( $opt eq "interval" ) {

        my $interval = shift @param;

        $interval = 60 unless defined($interval);
        if ( $interval < 5 ) { $interval = 5; }

        Log3 $name, 1, "EaseeWallbox_Set $name: Set interval to" . $interval;

        $hash->{INTERVAL} = $interval;
    }
    elsif ( $opt eq "presence" ) {

        my $status = shift @param;
        EaseeWallbox_UpdatePresenceStatus( $hash, $status );
    }
    readingsSingleUpdate( $hash, 'state', 'Initialized', 0 );
    return undef;
}

sub EaseeWallbox_LoadToken {
    my $hash          = shift;
    my $name          = $hash->{NAME};
    my $tokenLifeTime = $hash->{TOKEN_LIFETIME};
    $tokenLifeTime = 0 if ( !defined $tokenLifeTime || $tokenLifeTime eq '' );
    my $Token = undef;

    $Token = $hash->{'.TOKEN'};

    if ( $@ || $tokenLifeTime < gettimeofday() ) {
        Log3 $name, 5,
            "EaseeWallbox $name" . ": "
            . "Error while loading: $@ ,requesting new one"
            if $@;
        Log3 $name, 5,
            "EaseeWallbox $name" . ": "
            . "Token is expired, requesting new one"
            if $tokenLifeTime < gettimeofday();
        $Token = EaseeWallbox_NewTokenRequest($hash);
    }
    else {
        Log3 $name, 5,
              "EaseeWallbox $name" . ": "
            . "Token expires at "
            . localtime($tokenLifeTime);

        # if token is about to expire, refresh him
        if ( ( $tokenLifeTime - 45 ) < gettimeofday() ) {
            Log3 $name, 5,
                "EaseeWallbox $name" . ": "
                . "Token will expire soon, refreshing";
            $Token = EaseeWallbox_TokenRefresh($hash);
        }
    }
    return $Token if $Token;
}

sub EaseeWallbox_NewTokenRequest {
    my $hash = shift;
    my $name = $hash->{NAME};
    my $password
        = EaseeWallbox_decrypt( InternalVal( $name, 'Password', undef ) );
    my $username = InternalVal( $name, 'Username', undef );

    Log3 $name, 5, "EaseeWallbox $name" . ": " . "calling NewTokenRequest()";

    my $data = {
        userName => $username,
        password => $password,
    };

    my $param = {
        url     => $url{getOAuthToken},
        header  => { "Content-Type" => "application/json" },
        method  => 'POST',
        timeout => 5,
        hash    => $hash,
        data    => encode_json $data
    };
    Log3 $name, 5, 'Request: ' . Dumper($param);

    #Log3 $name, 5, 'Blocking GET: ' . Dumper($param);
    #Log3 $name, $reqDebug, "EaseeWallbox $name" . ": " . "Request $AuthURL";
    my ( $err, $returnData ) = HttpUtils_BlockingGet($param);

    if ( $err ne "" ) {
        Log3 $name, 3,
              "EaseeWallbox $name" . ": "
            . "NewTokenRequest: Error while requesting "
            . $param->{url}
            . " - $err";
    }
    elsif ( $returnData ne "" ) {
        Log3 $name, 5, "url " . $param->{url} . " returned: $returnData";
        my $decoded_data = eval { decode_json($returnData) };
        if ($@) {
            Log3 $name, 3, "EaseeWallbox $name" . ": "
                . "NewTokenRequest: decode_json failed, invalid json. error: $@ ";
        }
        else {
            #write token data in hash
            if ( defined($decoded_data) ) {
                $hash->{'.TOKEN'} = $decoded_data;
            }

            # token lifetime management
            if ( defined($decoded_data) ) {
                $hash->{TOKEN_LIFETIME}
                    = gettimeofday() + $decoded_data->{'expires_in'};
            }
            $hash->{TOKEN_LIFETIME_HR} = localtime( $hash->{TOKEN_LIFETIME} );
            Log3 $name, 5,
                  "EaseeWallbox $name" . ": "
                . "Retrived new authentication token successfully. Valid until "
                . localtime( $hash->{TOKEN_LIFETIME} );
            $hash->{STATE} = "reachable";
            return $decoded_data;
        }
    }
    return;
}

sub EaseeWallbox_TokenRefresh {
    my $hash = shift;
    my $name = $hash->{NAME};

    my $Token = undef;

    # load token
    $Token = $hash->{'.TOKEN'};

    my $data = {
        accessToken  => $Token->{'accessToken'},
        refreshToken => $Token->{'refreshToken'}
    };

    my $param = {
        url     => $url{getRefreshToken},
        header  => { "Content-Type" => "application/json" },
        method  => 'POST',
        timeout => 5,
        hash    => $hash,
        data    => encode_json $data
    };

    Log3 $name, 5, 'Request: ' . Dumper($param);

    #Log3 $name, 5, 'Blocking GET TokenRefresh: ' . Dumper($param);
    #Log3 $name, $reqDebug, "EaseeWallbox $name" . ": " . "Request $AuthURL";
    my ( $err, $returnData ) = HttpUtils_BlockingGet($param);

    if ( $err ne "" ) {
        Log3 $name, 3,
              "EaseeWallbox $name" . ": "
            . "TokenRefresh: Error in token retrival while requesting "
            . $param->{url}
            . " - $err";
        $hash->{STATE} = "error";
    }

    elsif ( $returnData ne "" ) {
        Log3 $name, 5, "url " . $param->{url} . " returned: $returnData";
        my $decoded_data = eval { decode_json($returnData); };

        if ($@) {
            Log3 $name, 3,
                "EaseeWallbox $name" . ": "
                . "TokenRefresh: decode_json failed, invalid json. error:$@\n"
                if $@;
            $hash->{STATE} = "error";
        }
        else {
            #write token data in file
            if ( defined($decoded_data) ) {
                $hash->{'.TOKEN'} = $decoded_data;

            }

            # token lifetime management
            $hash->{TOKEN_LIFETIME}
                = gettimeofday() + $decoded_data->{'expires_in'};
            $hash->{TOKEN_LIFETIME_HR} = localtime( $hash->{TOKEN_LIFETIME} );
            Log3 $name, 5,
                  "EaseeWallbox $name" . ": "
                . "TokenRefresh: Refreshed authentication token successfully. Valid until "
                . localtime( $hash->{TOKEN_LIFETIME} );
            $hash->{STATE} = "reachable";
            return $decoded_data;
        }
    }
    return;
}

sub EaseeWallbox_httpSimpleOperationOAuth($$$;$) {
    my ( $hash, $url, $operation, $message ) = @_;
    my ( $json, $err, $data, $decoded );
    my $name             = $hash->{NAME};
    my $CurrentTokenData = EaseeWallbox_LoadToken($hash);

    Log3 $name, 3,
        "$CurrentTokenData->{'tokenType'} $CurrentTokenData->{'accessToken'}";

    my $request = {
        url    => $url,
        header => {
            "Content-Type"  => "application/json;charset=UTF-8",
            "Authorization" =>
                "$CurrentTokenData->{'tokenType'} $CurrentTokenData->{'accessToken'}"
        },
        method  => $operation,
        timeout => 6,
        hideurl => 1
    };

    $request->{data} = $message if ( defined $message );
    Log3 $name, 5, 'Request: ' . Dumper($request);

    ( $err, $data ) = HttpUtils_BlockingGet($request);

    $json = "" if ( !$json );
    $data = "" if ( !$data );
    Log3 $name, 4, "FHEM -> EaseeWallbox: " . $url;
    Log3 $name, 4, "FHEM -> EaseeWallbox: " . $message
        if ( defined $message );
    Log3 $name, 4, "EaseeWallbox -> FHEM: " . $data if ( defined $data );
    Log3 $name, 4, "EaseeWallbox -> FHEM: Got empty response."
        if ( not defined $data );
    Log3 $name, 5, '$err: ' . $err;
    Log3 $name, 5, "method: " . $operation;
    Log3 $name, 2, "Something gone wrong"
        if ( $data =~ "/EaseeWallboxMode/" );

    $err = 1 if ( $data =~ "/EaseeWallboxMode/" );
    if ( defined $data and ( not $data eq '' ) and $operation ne 'DELETE' ) {
        eval {
            $decoded = decode_json($data) if ( !$err );
            Log3 $name, 5, 'Decoded: ' . Dumper($decoded);
            return $decoded;
        } or do {
            Log3 $name, 5, 'Failure decoding: ' . $@;
        }
    }
    else {
        return undef;
    }
}

sub EaseeWallbox_ExecuteParameterlessCommand($$) {
    my ( $hash, $template ) = @_;
    EaseeWallbox_ExecuteCommand($hash, 'POST', $template, undef)
}

sub EaseeWallbox_ExecuteCommand($@) {
    my ( $hash, $method, $template, $message ) = @_;
    my $name        = $hash->{NAME};
    my $urlTemplate = $url{$template};

    if ( not defined $hash ) {
        Log3 'EaseeWallbox', 1,
            "Error on EaseeWallbox_ExecuteCommand. Missing hash variable";
        return undef;
    }

    #Check if chargerID is required in URL and replace or alert.
    if ( $urlTemplate =~ m/#ChargerID#/ ) {
        my $chargerId = ReadingsVal( $name, 'charger_id', undef );
        if ( not defined $chargerId ) {
            Log3 'EaseeWallbox', 1,
                "Error on EaseeWallbox_ExecuteCommand. Missing charger_id. Please ensure basic data is available.";
            return undef;
        }
        $urlTemplate =~ s/#ChargerID#/$chargerId/g;
    }

    #Check if siteID is required in URL and replace or alert.
    if ( $urlTemplate =~ m/#SiteID#/ ) {
        my $siteId = ReadingsVal( $name, 'site_id', undef );
        if ( not defined $siteId ) {
            Log3 'EaseeWallbox', 1,
                "Error on EaseeWallbox_ExecuteCommand. Missing site_id. Please ensure basic data is available.";
            return undef;
        }
        $urlTemplate =~ s/#SiteID#/$siteId/g;         
    }

    Log3 $name, 4, "EaseeWallbox_ExecuteCommand will call Easee API for blocking value update. Name: $name";  
    my $d = EaseeWallbox_httpSimpleOperationOAuth( $hash, $urlTemplate, $method, encode_json \%$message );
}

sub EaseeWallbox_SetCableLock($$) {
    my ( $hash, $value ) = @_;
    my %message;
    $message{'state'} = $value;
    EaseeWallbox_ExecuteCommand($hash, "POST", "setCableLockState", \%message);
}

sub EaseeWallbox_SetPrice($$) {
    my ( $hash, $value ) = @_;
    my %message;
    $message{'currencyId'} = "EUR";
    $message{'vat'}        = "19";
    $message{'costPerKWh'} = $value;
    EaseeWallbox_ExecuteCommand($hash, "POST", "setChargingPrice", \%message);
}

sub EaseeWallbox_Attr(@) {
    return undef;
}

sub EaseeWallbox_GetChargers($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};

    if ( not defined $hash ) {
        my $msg = "Error on EaseeWallbox_GetChargers. Missing hash variable";
        Log3 'EaseeWallbox', 1, $msg;
        return $msg;
    }

    my $readTemplate = $url{"getChargers"};

    my $d = EaseeWallbox_httpSimpleOperationOAuth( $hash, $readTemplate,
        'GET' );

    if ( defined $d && ref($d) eq "HASH" && defined $d->{errors} ) {
        log 1, Dumper $d;
        readingsSingleUpdate( $hash,
            "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}",
            'Undefined', 1 );
        return undef;

    }
    else {

        readingsBeginUpdate($hash);

        my $site    = $d->[0];
        my $circuit = $site->{circuits}->[0];
        my $charger = $circuit->{chargers}->[0];

        readingsBeginUpdate($hash);
        my $chargerId = $charger->{id};
        readingsBulkUpdate( $hash, "charger_id",   $chargerId );
        readingsBulkUpdate( $hash, "charger_name", $charger->{name} );
        readingsBulkUpdate( $hash, "charger_isTemporary",
            $charger->{isTemporary} );
        readingsBulkUpdate( $hash, "charger_createdOn",
            $charger->{createdOn} );
        readingsEndUpdate( $hash, 1 );

        $readTemplate = $url{"getChargerDetails"};
        $readTemplate =~ s/#ChargerID#/$chargerId/g;
        $d = EaseeWallbox_httpSimpleOperationOAuth( $hash, $readTemplate,
            'GET' );

        if ( defined $d && ref($d) eq "HASH" && defined $d->{errors} ) {
            log 1, Dumper $d;
            readingsSingleUpdate( $hash,
                "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}",
                'Undefined', 1 );
            return undef;
        }
        else {
            readingsBeginUpdate($hash);
            readingsBulkUpdate( $hash, "charger_product",  $d->{product} );
            readingsBulkUpdate( $hash, "charger_pincode",  $d->{pinCode} );
            readingsBulkUpdate( $hash, "charger_unitType", $d->{unitType} );
            readingsEndUpdate( $hash, 1 );
        }

        return undef;
    }
}

sub EaseeWallbox_GetChargerConfig($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $chargerId = ReadingsVal( $name, "charger_id", undef );
    if ( not defined $chargerId ) {
        my $msg
            = "Error on EaseeWallbox_GetDevices. Missing Charger ID. Please get Chargers first.";
        Log3 'EaseeWallbox', 1, $msg;
        return $msg;
    }

    my $readTemplate = $url{"getChargerConfiguration"};
    $readTemplate =~ s/#ChargerID#/$chargerId/g;
    my $d = EaseeWallbox_httpSimpleOperationOAuth( $hash, $readTemplate,
        'GET' );

    if ( defined $d && ref($d) eq "HASH" && defined $d->{errors} ) {
        log 1, Dumper $d;
        readingsSingleUpdate( $hash, 'state',
            "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}", 1 );
        return undef;

    }
    else {

        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "charger_isEnabled", $d->{isEnabled} );
        readingsBulkUpdate(
            $hash,
            "charger_lockCablePermanently",
            $d->{lockCablePermanently}
        );
        readingsBulkUpdate(
            $hash,
            "charger_authorizationRequired",
            $d->{authorizationRequired}
        );
        readingsBulkUpdate( $hash, "charger_remoteStartRequired",
            $d->{remoteStartRequired} );
        readingsBulkUpdate( $hash, "charger_smartButtonEnabled",
            $d->{smartButtonEnabled} );
        readingsBulkUpdate( $hash, "charger_wiFiSSID", $d->{wiFiSSID} );
        readingsBulkUpdate( $hash, "charger_offlineChargingMode",
            $d->{offlineChargingMode} );
        readingsBulkUpdate( $hash, "charger_circuitMaxCurrentP1",
            $d->{circuitMaxCurrentP1} );
        readingsBulkUpdate( $hash, "charger_circuitMaxCurrentP2",
            $d->{circuitMaxCurrentP2} );
        readingsBulkUpdate( $hash, "charger_circuitMaxCurrentP3",
            $d->{circuitMaxCurrentP3} );
        readingsBulkUpdate( $hash, "charger_enableIdleCurrent",
            $d->{enableIdleCurrent} );
        readingsBulkUpdate(
            $hash,
            "charger_limitToSinglePhaseCharging",
            $d->{limitToSinglePhaseCharging}
        );
        readingsBulkUpdate( $hash, "charger_phaseModeId", $d->{phaseMode} );
        readingsBulkUpdate( $hash, "charger_phaseMode",
            $phaseMode{ $d->{phaseMode} } );
        readingsBulkUpdate( $hash, "charger_localNodeType",
            $d->{localNodeType} );
        readingsBulkUpdate(
            $hash,
            "charger_localAuthorizationRequired",
            $d->{localAuthorizationRequired}
        );
        readingsBulkUpdate( $hash, "charger_localRadioChannel",
            $d->{localRadioChannel} );
        readingsBulkUpdate( $hash, "charger_localShortAddress",
            $d->{localShortAddress} );
        readingsBulkUpdate(
            $hash,
            "charger_localParentAddrOrNumOfNodes",
            $d->{localParentAddrOrNumOfNodes}
        );
        readingsBulkUpdate(
            $hash,
            "charger_localPreAuthorizeEnabled",
            $d->{localPreAuthorizeEnabled}
        );
        readingsBulkUpdate(
            $hash,
            "charger_allowOfflineTxForUnknownId",
            $d->{allowOfflineTxForUnknownId}
        );
        readingsBulkUpdate( $hash, "charger_maxChargerCurrent",
            $d->{maxChargerCurrent} );
        readingsBulkUpdate( $hash, "charger_ledStripBrightness",
            $d->{ledStripBrightness} );
        readingsBulkUpdate( $hash, "charger_chargingSchedule",
            $d->{chargingSchedule} );

        readingsEndUpdate( $hash, 1 );

        return undef;
    }

    EaseeWallbox_RequestDeviceUpdate($hash);
}

sub EaseeWallbox_GetChargerSite($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $chargerId = ReadingsVal( $name, "charger_id", undef );
    if ( not defined $chargerId ) {
        my $msg
            = "Error on EaseeWallbox_GetChargerSite. Missing Charger ID. Please get Chargers first.";
        Log3 'EaseeWallbox', 1, $msg;
        return $msg;
    }

    my $readTemplate = $url{"getChargerSite"};
    $readTemplate =~ s/#ChargerID#/$chargerId/g;
    my $d = EaseeWallbox_httpSimpleOperationOAuth( $hash, $readTemplate,
        'GET' );

    if ( defined $d && ref($d) eq "HASH" && defined $d->{errors} ) {
        log 1, Dumper $d;
        readingsSingleUpdate( $hash, 'state',
            "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}", 1 );
        return undef;

    }
    else {

        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "site_key",    $d->{siteKey} );
        readingsBulkUpdate( $hash, "site_id",     $d->{id} );
        readingsBulkUpdate( $hash, "cost_perKWh", $d->{costPerKWh} );
        readingsBulkUpdate( $hash, "cost_perKwhExcludeVat",
            $d->{costPerKwhExcludeVat} );
        readingsBulkUpdate( $hash, "cost_vat",          $d->{vat} );
        readingsBulkUpdate( $hash, "cost_currency",     $d->{currencyId} );
        readingsBulkUpdate( $hash, "site_ratedCurrent", $d->{ratedCurrent} );
        readingsBulkUpdate( $hash, "site_createdOn",    $d->{createdOn} );
        readingsBulkUpdate( $hash, "site_updatedOn",    $d->{updatedOn} );
        readingsEndUpdate( $hash, 1 );
        return undef;
    }

    EaseeWallbox_RequestDeviceUpdate($hash);
}

sub EaseeWallbox_RequestCurrentSessionCallback($) {

    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ( $err ne "" )   # wenn ein Fehler bei der HTTP Abfrage aufgetreten ist
    {
        Log3 $name, 3,
              "error while requesting "
            . $param->{url}
            . " - $err";    # Eintrag fürs Log
        readingsSingleUpdate( $hash, "state", "ERROR", 1 );
        return undef;
    }

    Log3 $name, 3,
        "Received non-blocking data from EaseeWallbox regarding current session ";

    Log3 $name, 4, "FHEM -> EaseeWallbox: " . $param->{url};
    Log3 $name, 4, "FHEM -> EaseeWallbox: " . $param->{message}
        if ( defined $param->{message} );
    Log3 $name, 4, "EaseeWallbox -> FHEM: " . $data;
    Log3 $name, 5, '$err: ' . $err;
    Log3 $name, 5, "method: " . $param->{method};
    Log3 $name, 2, "Something gone wrong"
        if ( $data =~ "/EaseeWallboxMode/" );
    eval {
        my $d = decode_json($data) if ( !$err );
        Log3 $name, 5, 'Decoded: ' . Dumper($d);

        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "session_energy", $d->{sessionEnergy} );
        readingsBulkUpdate( $hash, "session_start",  $d->{sessionStart} );
        readingsBulkUpdate( $hash, "session_end",    $d->{sessionEnd} );
        readingsBulkUpdate(
            $hash,
            "session_chargeDurationInSeconds",
            $d->{chargeDurationInSeconds}
        );
        readingsBulkUpdate( $hash, "session_firstEnergyTransfer",
            $d->{firstEnergyTransferPeriodStart} );
        readingsBulkUpdate( $hash, "session_lastEnergyTransfer",
            $d->{lastEnergyTransferPeriodStart} );
        readingsBulkUpdate( $hash, "session_pricePerKWH",
            $d->{pricePrKwhIncludingVat} );
        readingsBulkUpdate( $hash, "session_chargingCost",
            $d->{costIncludingVat} );
        readingsBulkUpdate( $hash, "session_id", $d->{sessionId} );
        readingsEndUpdate( $hash, 1 );

        return undef;
    } or do {
        Log3 $name, 5, 'Failure decoding: ' . $@;
        return undef;
    }
}

sub EaseeWallbox_RequestChargerStateCallback($) {

    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ( $err ne "" )   # wenn ein Fehler bei der HTTP Abfrage aufgetreten ist
    {
        Log3 $name, 3,
              "error while requesting "
            . $param->{url}
            . " - $err";    # Eintrag fürs Log
        readingsSingleUpdate( $hash, "state", "ERROR", 1 );
        return undef;
    }

    Log3 $name, 3,
        "Received non-blocking data from EaseeWallbox regarding current state ";

    Log3 $name, 4, "FHEM -> EaseeWallbox: " . $param->{url};
    Log3 $name, 4, "FHEM -> EaseeWallbox: " . $param->{message}
        if ( defined $param->{message} );
    Log3 $name, 4, "EaseeWallbox -> FHEM: " . $data;
    Log3 $name, 5, '$err: ' . $err;
    Log3 $name, 5, "method: " . $param->{method};
    Log3 $name, 2, "Something gone wrong"
        if ( $data =~ "/EaseeWallboxMode/" );
    eval {
        my $d = decode_json($data) if ( !$err );
        Log3 $name, 5, 'Decoded: ' . Dumper($d);

        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "actual_operationModeCode",
            $d->{chargerOpMode} );
        readingsBulkUpdate( $hash, "actual_operationMode",
            $operationMode{ $d->{chargerOpMode} } );

        readingsBulkUpdate( $hash, "actual_power", $d->{totalPower} );
        readingsBulkUpdate( $hash, "actual_kWhInSession",
            $d->{sessionEnergy} );
        readingsBulkUpdate( $hash, "actual_phase",       $d->{outputPhase} );
        readingsBulkUpdate( $hash, "actual_latestPulse", $d->{latestPulse} );
        readingsBulkUpdate( $hash, "actual_current", $d->{outputCurrent} );
        readingsBulkUpdate( $hash, "actual_dynamicCurrent",
            $d->{dynamicChargerCurrent} );

        readingsBulkUpdate(
            $hash,
            "actual_reasonCodeForNoCurrent",
            $d->{reasonForNoCurrent}
        );
        readingsBulkUpdate( $hash, "actual_reasonForNoCurrent",
            $reasonForNoCurrent{ $d->{reasonForNoCurrent} } );

        readingsBulkUpdate( $hash, "errorCode",      $d->{errorCode} );
        readingsBulkUpdate( $hash, "fatalErrorCode", $d->{fatalErrorCode} );

        readingsBulkUpdate( $hash, "lifetimeEnergy", $d->{lifetimeEnergy} );
        readingsBulkUpdate( $hash, "online",         $d->{isOnline} );
        readingsBulkUpdate( $hash, "voltage",        $d->{voltage} );
        readingsBulkUpdate( $hash, "wifi_rssi",      $d->{wiFiRSSI} );
        readingsBulkUpdate( $hash, "wifi_apEnabled", $d->{wiFiAPEnabled} );
        readingsBulkUpdate( $hash, "cell_rssi",      $d->{cellRSSI} );
        readingsEndUpdate( $hash, 1 );

        return undef;
    } or do {
        Log3 $name, 5, 'Failure decoding: ' . $@;
        return undef;
    }
}

sub EaseeWallbox_UpdateDueToTimer($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};

#local allows call of function without adding new timer.
#must be set before call ($hash->{LOCAL} = 1) and removed after (delete $hash->{LOCAL};)
    if ( !$hash->{LOCAL} ) {
        RemoveInternalTimer($hash);

        #Log3 "Test", 1, Dumper($hash);
        InternalTimer(
            gettimeofday() + InternalVal( $name, 'INTERVAL', undef ),
            "EaseeWallbox_UpdateDueToTimer", $hash );
        readingsSingleUpdate( $hash, 'state', 'Polling', 0 );
    }

    #EaseeWallbox_RequestZoneUpdate($hash);
    #EaseeWallbox_RequestAirComfortUpdate($hash);
    #EaseeWallbox_RequestMobileDeviceUpdate($hash);
    #EaseeWallbox_RequestWeatherUpdate($hash);

    #EaseeWallbox_RequestDeviceUpdate($hash);
    #EaseeWallbox_RequestPresenceUpdate($hash);
}

sub EaseeWallbox_RequestCurrentSession($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    if ( not defined $hash ) {
        Log3 'EaseeWallbox', 1,
            "Error on EaseeWallbox_RequestCurrentSession. Missing hash variable";
        return undef;
    }

    if ( not defined ReadingsVal( $name, 'charger_id', undef ) ) {
        Log3 'EaseeWallbox', 1,
            "Error on EaseeWallbox_RequestCurrentSession. Missing charger_id. Please fetch basic data first.";
        return undef;
    }
    my $chargerId = ReadingsVal( $name, "charger_id", undef );

    $hash->{charger} = $chargerId;

    Log3 $name, 4,
        "EaseeWallbox_RequestCurrentSession Called for non-blocking value update. Name: $name";

    my $readTemplate = $url{"getCurrentSession"};
    $readTemplate =~ s/#ChargerID#/$chargerId/g;

    my $CurrentTokenData = EaseeWallbox_LoadToken($hash);
    my $token
        = "$CurrentTokenData->{'tokenType'} $CurrentTokenData->{'accessToken'}";
    Log3 $name, 4, "token beeing used: " . $token;

    my $request = {
        url    => $readTemplate,
        header => {
            "Content-Type"  => "application/json;charset=UTF-8",
            "Authorization" => $token,
        },
        method   => 'GET',
        timeout  => 5,
        hideurl  => 1,
        callback => \&EaseeWallbox_RequestCurrentSessionCallback,
        hash     => $hash
    };

    Log3 $name, 5, 'NonBlocking Request: ' . Dumper($request);

    HttpUtils_NonblockingGet($request);
}

sub EaseeWallbox_RequestChargerState($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    if ( not defined $hash ) {
        Log3 'EaseeWallbox', 1,
            "Error on EaseeWallbox_RequestChargerState. Missing hash variable";
        return undef;
    }

    if ( not defined ReadingsVal( $name, 'charger_id', undef ) ) {
        Log3 'EaseeWallbox', 1,
            "Error on EaseeWallbox_RequestChargerState. Missing charger_id. Please fetch basic data first.";
        return undef;
    }
    my $chargerId = ReadingsVal( $name, "charger_id", undef );

    $hash->{charger} = $chargerId;

    Log3 $name, 4,
        "EaseeWallbox_RequestChargerState Called for non-blocking value update. Name: $name";

    my $readTemplate = $url{"getChargerState"};
    $readTemplate =~ s/#ChargerID#/$chargerId/g;

    my $CurrentTokenData = EaseeWallbox_LoadToken($hash);
    my $token
        = "$CurrentTokenData->{'tokenType'} $CurrentTokenData->{'accessToken'}";
    Log3 $name, 4, "token beeing used: " . $token;

    my $request = {
        url    => $readTemplate,
        header => {
            "Content-Type"  => "application/json;charset=UTF-8",
            "Authorization" => $token,
        },
        method   => 'GET',
        timeout  => 5,
        hideurl  => 1,
        callback => \&EaseeWallbox_RequestChargerStateCallback,
        hash     => $hash
    };

    Log3 $name, 5, 'NonBlocking Request: ' . Dumper($request);

    HttpUtils_NonblockingGet($request);
}

sub EaseeWallbox_encrypt($) {
    my ($decoded) = @_;
    my $key = getUniqueId();
    my $encoded;

    return $decoded if ( $decoded =~ /crypt:/ );

    for my $char ( split //, $decoded ) {
        my $encode = chop($key);
        $encoded .= sprintf( "%.2x", ord($char) ^ ord($encode) );
        $key = $encode . $key;
    }

    return 'crypt:' . $encoded;
}

sub EaseeWallbox_decrypt($) {
    my ($encoded) = @_;
    my $key = getUniqueId();
    my $decoded;

    return $encoded if ( $encoded !~ /crypt:/ );

    $encoded = $1 if ( $encoded =~ /crypt:(.*)/ );

    for my $char ( map { pack( 'C', hex($_) ) } ( $encoded =~ /(..)/g ) ) {
        my $decode = chop($key);
        $decoded .= chr( ord($char) ^ ord($decode) );
        $key = $decode . $key;
    }

    return $decoded;
}

1;

=pod
=begin html

<a name="EaseeWallbox"></a>
<h3>EaseeWallbox</h3>
<ul>
    <i>EaseeWallbox</i> implements an interface to the EaseeWallbox cloud. The plugin can be used to read and write temperature and settings from or to the EaseeWallbox cloud. The communication is based on the reengineering of the protocol done by Stephen C. Phillips. See <a href="http://blog.scphillips.com/posts/2017/01/the-EaseeWallbox-api-v2/">his blog</a> for more details. Not all functions are implemented within this FHEM extension. By now the plugin is capable to interact with the so called zones (rooms) and the registered devices. The devices cannot be controlled directly. All interaction - like setting a temperature - must be done via the zone and not the device. This means all configuration like the registration of new devices or the assignment of a device to a room must be done using the EaseeWallbox app or EaseeWallbox website directly. Once the configuration is completed this plugin can be used. This device is the 'bridge device' like a HueBridge or a CUL. Per zone or device a dedicated device of type 'EaseeWallbox' will be created.
    The following features / functionalities are defined by now when using EaseeWallbox and EaseeWallboxs:
    <ul>
        <li>EaseeWallbox Bridge
        <br><ul>
            <li>Manages the communication towards the EaseeWallbox cloud environment and documents the status in several readings like which data was refreshed, when it was rerefershed, etc.</li>
            <li><b>Overall Presence status</b> Indicates wether at least one mobile device is 'at Home'</li>
            <li><b>Overall Air Comfort</b> Indicates the air comfort of the whole home.</li>
        </ul></li>
        <li>Zone (basically a room)
        <br><ul>
            <li><b>Temperature Management:</b> Displays the current temperature, allows to set the desired temperature including the EaseeWallbox modes which can do this manually or automatically</li>
            <li><b>Zone Air Comfort</b> Indicates the air comfort of the specific room.</li>
        </ul></li>
        <li>Device
           <br><ul>
            <li><b>Connection State:</b> Indicate when the actual device was seen the last time</li>
            <li><b>Battery Level</b> Indicates the current battery level of the device.</li>
            <li><b>Find device</b> Output a 'Hi' message on the display to identify the specific device</li>
        </ul></li>
        <li>Mobile Device<
          <br><ul>
            <li><b>Device Configration:</b> Displays information about the device type and the current configuration (view only)</li>
            <li><b>Presence status</b> Indicates if the specific mobile device is Home or Away.</li>
        </ul></li>
        <li>Weather
          <br><ul>
            <li>Displays information about the ouside waether and the solar intensity (cloud source, not actually measured).</li>
        </ul></li>
    </ul>
    <br>
    While previous versions of this plugin were using plain authentication encoding the username and the password directly in the URL this version now uses OAuth2 which does a secure authentication and uses security tokens afterwards. This is a huge security improvement. The implementation is based on code written by Philipp (Psycho160). Thanks for sharing.
    <br>
    <br>
    <a name="EaseeWallboxdefine"></a>
    <b>Define</b>
    <ul>
        <code>define &lt;name&gt; EaseeWallbox &lt;username&gt; &lt;password&gt; &lt;interval&gt;</code>
        <br>
        <br> Example: <code>define EaseeWallboxBridge EaseeWallbox mail@provider.com somepassword 120</code>
        <br>
        <br> The username and password must match the username and password used on the EaseeWallbox website. Please be aware that username and password are stored and send as plain text. They are visible in FHEM user interface. It is recommended to create a dedicated user account for the FHEM integration. The EaseeWallbox extension needs to pull the data from the EaseeWallbox website. The 'Interval' value defines how often the value is refreshed.
    </ul>
    <br>
    <b>Set</b>
    <br>
    <ul>
        <code>set &lt;name&gt; &lt;option&gt;</code>
        <br>
        <br> The <i>set</i> command just offers very limited options. If can be used to control the refresh mechanism. The plugin only evaluates the command. Any additional information is ignored.
        <br>
        <br> Options:
        <ul>
            <li><i>interval</i>
                <br> Sets how often the values shall be refreshed. This setting overwrites the value set during define.</li>
            <li><i>start</i>
                <br> (Re)starts the automatic refresh. Refresh is autostarted on define but can be stopped using stop command. Using the start command FHEM will start polling again.</li>
            <li><i>stop</i>
                <br> Stops the automatic polling used to refresh all values.</li>
            <li><i>presence</i>
                <br> Sets the presence value for the whole EaseeWallbox account. You can set the status to HOME or AWAY and depending on the status all devices will chnange their confiration between home and away mode. If you're using the mobile devices and the EaseeWallbox premium feature using geofencing to determine home and away status you should not use this function.</li>
        </ul>
    </ul>
    <br>
    <a name="EaseeWallboxget"></a>
    <b>Get</b>
    <br>
    <ul>
        <code>get &lt;name&gt; &lt;option&gt;</code>
        <br>
        <br> You can <i>get</i> the major information from the EaseeWallbox cloud.
        <br>
        <br> Options:
        <ul>
            <li><i>home</i>
                <br> Gets the home identifier from EaseeWallbox cloud. The home identifier is required for all further actions towards the EaseeWallbox cloud. Currently the FHEM extension only supports a single home. If you have more than one home only the first home is loaded.
                <br/><b>This function is automatically executed once when a new EaseeWallbox device is defined.</b></li>
            <li><i>zones</i>
                <br> Every zone in the EaseeWallbox cloud represents a room. This command gets all zones defined for the current home. Per zone a new FHEM device is created. The device can be used to display and overwrite the current temperatures. This command can always be executed to update the list of defined zones. It will not touch any existing zone but add new zones added since last update.
                <br/><b>This function is automatically executed once when a new EaseeWallbox device is defined.</b></li>
            <li><i>update</i>
                <br/> Updates the values of:
                <br/>
                <ul>
                    <li>All EaseeWallbox zones</li>
                    <li>The presence status of the whole EaseeWallbox account</li>
                    <li>All mobile devices - if attribute <i>generateMobileDevices</i> is set to true</li>
                    <li>All devices - if attribute <i>generateDevices</i> is set to true</li>
                    <li>The weather device - if attribute <i>generateWeather</i> is set to true</li>
                </ul>
                This command triggers a single update not a continuous refresh of the values.
            </li>
            <li><i>devices</i>
                <br/> Fetches all devices from EaseeWallbox cloud and creates one EaseeWallbox instance per fetched device. This command will only be executed if the attribute <i>generateDevices</i> is set to <i>yes</i>. If the attribute is set to <i>no</i> or not existing an error message will be displayed and no communication towards EaseeWallbox will be done. This command can always be executed to update the list of defined devices. It will not touch existing devices but add new ones. Devices will not be updated automatically as there are no values continuously changing.
            </li>
            <li><i>mobile_devices</i>
                <br/> Fetches all defined mobile devices from EaseeWallbox cloud and creates one EaseeWallbox instance per mobile device. This command will only be executed if the attribute <i>generateMobileDevices</i> is set to <i>yes</i>. If the attribute is set to <i>no</i> or not existing an error message will be displayed and no communication towards EaseeWallbox will be done. This command can always be executed to update the list of defined mobile devices. It will not touch existing devices but add new ones.
            </li>
            <li><i>weather</i>
                <br/> Creates or updates an additional device for the data bridge containing the weather data provided by EaseeWallbox. This command will only be executed if the attribute <i>generateWeather</i> is set to <i>yes</i>. If the attribute is set to <i>no</i> or not existing an error message will be displayed and no communication towards EaseeWallbox will be done.
            </li>
        </ul>
    </ul>
    <br>
    <a name="EaseeWallboxattr"></a>
    <b>Attributes</b>
    <ul>
        <code>attr &lt;name&gt; &lt;attribute&gt; &lt;value&gt;</code>
        <br>
        <br> You can change the behaviour of the EaseeWallbox Device.
        <br>
        <br> Attributes:
        <ul>
            <li><i>generateDevices</i>
                <br> By default the devices are not fetched and displayed in FHEM as they don't offer much functionality. The functionality is handled by the zones not by the devices. But the devices offers an identification function <i>sayHi</i> to show a message on the specific display. If this function is required the Devices can be generated. Therefor the attribute <i>generateDevices</i> must be set to <i>yes</i>
                <br/><b>If this attribute is set to <i>no</i> or if the attribute is not existing no devices will be generated..</b>
            </li>
            <li><i>generateMobileDevices</i>
                <br> By default the mobile devices are not fetched and displayed in FHEM as most users already have a person home recognition. If EaseeWallbox shall be used to identify if a mobile device is at home this can be done using the mobile devices. In this case the mobile devices can be generated. Therefor the attribute <i>generateMobileDevices</i> must be set to <i>yes</i>
                <br/><b>If this attribute is set to <i>no</i> or if the attribute is not existing no mobile devices will be generated..</b>
            </li>
            <li><i>generateWeather</i>
                <br> By default no weather channel is generated. If you want to use the weather as it is defined by the EaseeWallbox system for your specific environment you must set this attribute. If the attribute <i>generateWeather</i> is set to <i>yes</i> an additional weather channel can be generated.
                <br/><b>If this attribute is set to <i>no</i> or if the attribute is not existing no Devices will be generated..</b>
            </li>
        </ul>
 </ul>
    <br>
    <a name="EaseeWallboxreadings"></a>
    <b>Generated Readings/Events:</b>
        <br>
    <ul>
        <ul>
            <li><b>DeviceCount</b>
                <br> Indicates how many devices (hardware devices provided by EaseeWallbox) are registered in the linked EaseeWallbox Account.
                <br/> This reading will only be available / updated if the attribute <i>generateDevices</i> is set to <i>yes</i>.
            </li>
            <li><b>LastUpdate_Devices</b>
                <br> Indicates when the last successful request to update the hardware devices (EaseeWallboxs) was send to the EaseeWallbox API. his reading will only be available / updated if the attribute <i>generateDevices</i> is set to <i>yes</i>.
            </li>
            <li><b>HomeID</b>
                <br> Unique identifier for your EaseeWallbox account instance. All devices are linked to your homeID and the homeID required for almost all EaseeWallbox API requests.
            </li>
            <li><b>HomeName</b>
                <br> Name of your EaseeWallbox home as you have configured it in your EaseeWallbox account.
            </li>
            <li><b>Presence</b>
                <br> The current presence status of your home. The status can be HOME or AWAY and is valid for the whole home and all devices and zones linked to this home. The Presence reading can be influences by the <i>set presence</i> command or based on geofencing using mobile devices.
            </li>
            <li><b>airComfort_freshness</b>
                <br> The overall fresh air indicator for your home. Represents a summary of the single indicators per zone / room.
            </li>
            <li><b>airComfort_lastWindowOpen</b>
                <br> Inidcates the last time an open window was detected by EaseeWallbox to refresh the air within the home.
            </li>
            <li><b>LastUpdate_AirComfort</b>
                <br> Indicates when the last successful request to update the air comfort was send to the EaseeWallbox API.
            </li>
            <li><b>LastUpdate_MobileDevices</b>
                <br> Indicates when the last successful request to update the mobile devices was send to the EaseeWallbox API. his reading will only be available / updated if the attribute <i>generateMobileDevices</i> is set to <i>yes</i>.
            </li>
            <li><b>LastUpdate_Weather</b>
                <br> Indicates when the last successful request to update the weather was send to the EaseeWallbox API. his reading will only be available / updated if the attribute <i>generateWeather</i> is set to <i>yes</i>.
            </li>
            <li><b>LastUpdate_Zones</b>
                <br> Indicates when the last successful request to update the zone / room data was send to the EaseeWallbox API.
            </li>
        </ul>
    </ul>
</ul>

=end html

=cut
