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
    baseData => "noArg",
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
    pricePerKWH              => "",
    activateTimer            => "",
    deactivateTimer          => "",
);

my %EaseeWallbox_urls = (
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

my %EaseeWallbox_reasonsForNoCurrent = (
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
my %EaseeWallbox_phaseModes = (
    1 => 'Locked to single phase',
    2 => 'Auto',
    3 => 'Locked to three phase',
);

my %EaseeWallbox_operationModes = (
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

        Log3 ($name, 5, "parse cmd-table - Set:$mySet, Option:$myOpt, RetVal:$retVal");
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
    EaseeWallbox_UpdateBaseData($hash);
    EaseeWallbox_RefreshData($hash);

    Log3 $name, 1, sprintf("EaseeWallbox_Define %s: Starting timer with interval %s", $name, InternalVal($name,'INTERVAL', undef));
    InternalTimer(gettimeofday()+ InternalVal($name,'INTERVAL', undef), "EaseeWallbox_UpdateDueToTimer", $hash) if (defined $hash);
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

    $hash->{LOCAL} = 1;
    EaseeWallbox_GetChargers($hash)         if $opt eq "chargers";
    EaseeWallbox_GetChargerConfig($hash)    if $opt eq "config";
    EaseeWallbox_GetChargerSite($hash)      if $opt eq "sites";
    EaseeWallbox_RefreshData($hash)         if $opt eq "update";
    EaseeWallbox_UpdateBaseData($hash)      if $opt eq 'baseData';        
    delete $hash->{LOCAL};
    return undef;        
}

sub EaseeWallbox_Set($@) {
    my ( $hash, $name, @param ) = @_;

    return '"set $name" needs at least one argument' if ( int(@param) < 1 );

    my $opt   = shift @param;
    my $value = join( "", @param );

    #create response, if cmd is wrong or gui asks
    my $cmdTemp = EaseeWallbox_getCmdList( $hash, $opt, \%EaseeWallbox_sets );
    return $cmdTemp if ( defined($cmdTemp) );

    if ( $opt eq "deactivateTimer" ) {
        RemoveInternalTimer($hash);
        Log3 $name, 1,
            "EaseeWallbox_Set $name: Stopped the timer to automatically update readings";
        readingsSingleUpdate( $hash, 'state', 'Initialized', 0 );
        return undef;
    }
     elsif ( $opt eq "activateTimer" ) {
        #Update once manually and then start the timer
        RemoveInternalTimer($hash);
        $hash->{LOCAL} = 1;
        EaseeWallbox_RefreshData($hash);
        delete $hash->{LOCAL};      
        InternalTimer(gettimeofday()+ InternalVal($name,'INTERVAL', undef), "EaseeWallbox_UpdateDueToTimer", $hash);
        readingsSingleUpdate($hash,'state','Started',0);  
        Log3 $name, 1, sprintf("EaseeWallbox_Set %s: Updated readings and started timer to automatically update readings with interval %s", $name, InternalVal($name,'INTERVAL', undef));
    }
    elsif ( $opt eq "interval" ) {
        my $interval = shift @param;

        $interval = 60 unless defined($interval);
        if ( $interval < 5 ) { $interval = 5; }

        Log3 $name, 1, "EaseeWallbox_Set $name: Set interval to" . $interval;
        $hash->{INTERVAL} = $interval;
    } else {
        $hash->{LOCAL} = 1;
        EaseeWallbox_ExecuteParameterlessCommand( $hash, "setStartCharging" )        if $opt eq "startCharging";
        EaseeWallbox_ExecuteParameterlessCommand( $hash, "setStopCharging" )         if $opt eq 'stopCharging';  
        EaseeWallbox_ExecuteParameterlessCommand( $hash, "setPauseCharging" )        if $opt eq 'pauseCharging';
        EaseeWallbox_ExecuteParameterlessCommand( $hash, "setResumeCharging" )       if $opt eq 'resumeCharging';
        EaseeWallbox_ExecuteParameterlessCommand( $hash, "setToggleCharging" )       if $opt eq 'toggleCharging';      
        EaseeWallbox_ExecuteParameterlessCommand( $hash, "setUpdateFirmware" )       if $opt eq 'updateFirmware';
        EaseeWallbox_ExecuteParameterlessCommand( $hash, "setOverrideChargingSchedule" )       if $opt eq 'overrideChargingSchedule';
        EaseeWallbox_ExecuteParameterlessCommand( $hash, "setPairRFIDTag" )       if $opt eq 'pairRfidTag';     

        EaseeWallbox_ExecuteParameterlessCommand( $hash, "setReboot" )               if $opt eq 'reboot';
        EaseeWallbox_ExecuteParameterlessCommand( $hash, "toBeDone" )                if $opt eq 'enableSmartCharging';
        EaseeWallbox_SetCableLock( $hash, shift @param )                             if $opt eq 'cableLock';
        EaseeWallbox_SetPrice( $hash, shift @param )                                 if $opt eq 'pricePerKWH';
        EaseeWallbox_LoadToken($hash)                                                if $opt eq 'refreshToken';   
        delete $hash->{LOCAL};
    }
    readingsSingleUpdate( $hash, 'state', 'Initialized', 0 );
    return undef;
}

sub EaseeWallbox_RefreshData($){
    my $hash     = shift;    
    my $name     = $hash->{NAME};
    EaseeWallbox_GetChargerSite($hash);    
    EaseeWallbox_RequestChargerState($hash);
    EaseeWallbox_RequestCurrentSession($hash);
    readingsSingleUpdate( $hash, "state", sprintf('%s (%.2f)<br/>Current Session: %.2f kWH (%.2f€)', ReadingsVal($name,"operationMode","N/A"), ReadingsVal($name,"power","0"), ReadingsVal($name,"kWhInSession","0"), ReadingsVal($name,"session_chargingCost","0")), 1 );
}

sub EaseeWallbox_UpdateBaseData($){
    my $hash          = shift;    
    EaseeWallbox_GetChargers($hash);
    EaseeWallbox_GetChargerConfig($hash);
    EaseeWallbox_RefreshData($hash);    
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
        if ( ( $tokenLifeTime - 3700 ) < gettimeofday() ) {
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
        url     => $EaseeWallbox_urls{getOAuthToken},
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
                    = gettimeofday() + $decoded_data->{'expiresIn'};
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
        url     => $EaseeWallbox_urls{getRefreshToken},
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
    my $urlTemplate = $EaseeWallbox_urls{$template};

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

    my $readTemplate = $EaseeWallbox_urls{"getChargers"};

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
        #readingsBulkUpdate( $hash, "charger_isTemporary", $charger->{isTemporary} );
        #readingsBulkUpdate( $hash, "charger_createdOn", $charger->{createdOn} );
        readingsEndUpdate( $hash, 1 );

        $readTemplate = $EaseeWallbox_urls{"getChargerDetails"};
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
            readingsBulkUpdate( $hash, "product",  $d->{product} );
            readingsBulkUpdate( $hash, "pincode",  $d->{pinCode} );
            readingsBulkUpdate( $hash, "unitType", $d->{unitType} );
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

    my $readTemplate = $EaseeWallbox_urls{"getChargerConfiguration"};
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
            "lockCablePermanently",
            $d->{lockCablePermanently}
        );
        readingsBulkUpdate(
            $hash,
            "authorizationRequired",
            $d->{authorizationRequired}
        );
        readingsBulkUpdate( $hash, "remoteStartRequired",
            $d->{remoteStartRequired} );
        readingsBulkUpdate( $hash, "smartButtonEnabled",
            $d->{smartButtonEnabled} );
        readingsBulkUpdate( $hash, "wiFiSSID", $d->{wiFiSSID} );
        #readingsBulkUpdate( $hash, "charger_offlineChargingMode",
        #    $d->{offlineChargingMode} );
        #readingsBulkUpdate( $hash, "charger_circuitMaxCurrentP1",
        #    $d->{circuitMaxCurrentP1} );
        #readingsBulkUpdate( $hash, "charger_circuitMaxCurrentP2",
        #    $d->{circuitMaxCurrentP2} );
        #readingsBulkUpdate( $hash, "charger_circuitMaxCurrentP3",
        #    $d->{circuitMaxCurrentP3} );
        #readingsBulkUpdate( $hash, "charger_enableIdleCurrent",
        #    $d->{enableIdleCurrent} );
        #readingsBulkUpdate(
        #    $hash,
        #    "charger_limitToSinglePhaseCharging",
        #    $d->{limitToSinglePhaseCharging}
        #);
        readingsBulkUpdate( $hash, "charger_phaseModeId", $d->{phaseMode} );
        readingsBulkUpdate( $hash, "charger_phaseMode",
            $EaseeWallbox_phaseModes{ $d->{phaseMode} } );
        #readingsBulkUpdate( $hash, "charger_localNodeType",
        #    $d->{localNodeType} );
        readingsBulkUpdate(
            $hash,
            "localAuthorizationRequired",
            $d->{localAuthorizationRequired}
        );
        #readingsBulkUpdate( $hash, "charger_localRadioChannel",
        #    $d->{localRadioChannel} );
        #readingsBulkUpdate( $hash, "charger_localShortAddress",
        #    $d->{localShortAddress} );
        #readingsBulkUpdate(
        #    $hash,
        #    "charger_localParentAddrOrNumOfNodes",
        #    $d->{localParentAddrOrNumOfNodes}
        #);
        #readingsBulkUpdate(
        #    $hash,
        #    "charger_localPreAuthorizeEnabled",
        #    $d->{localPreAuthorizeEnabled}
        #);
        #readingsBulkUpdate(
        #    $hash,
        #    "charger_allowOfflineTxForUnknownId",
        #    $d->{allowOfflineTxForUnknownId}
        #);
        readingsBulkUpdate( $hash, "maxChargerCurrent",
            $d->{maxChargerCurrent} );
        readingsBulkUpdate( $hash, "ledStripBrightness",
            $d->{ledStripBrightness} );
        #readingsBulkUpdate( $hash, "chargingSchedule",
        #    $d->{chargingSchedule} );

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

    my $readTemplate = $EaseeWallbox_urls{"getChargerSite"};
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
        #readingsBulkUpdate( $hash, "site_ratedCurrent", $d->{ratedCurrent} );
        #readingsBulkUpdate( $hash, "site_createdOn",    $d->{createdOn} );
        #readingsBulkUpdate( $hash, "site_updatedOn",    $d->{updatedOn} );
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
        readingsBulkUpdate( $hash, "operationModeCode",
            $d->{chargerOpMode} );
        readingsBulkUpdate( $hash, "operationMode",
            $EaseeWallbox_operationModes{ $d->{chargerOpMode} } );

        readingsBulkUpdate( $hash, "power", $d->{totalPower} );
        readingsBulkUpdate( $hash, "kWhInSession",
            $d->{sessionEnergy} );
        readingsBulkUpdate( $hash, "phase",       $d->{outputPhase} );
        readingsBulkUpdate( $hash, "latestPulse", $d->{latestPulse} );
        readingsBulkUpdate( $hash, "current", $d->{outputCurrent} );
        readingsBulkUpdate( $hash, "dynamicCurrent",
            $d->{dynamicChargerCurrent} );

        readingsBulkUpdate(
            $hash,
            "reasonCodeForNoCurrent",
            $d->{reasonForNoCurrent}
        );
        readingsBulkUpdate( $hash, "reasonForNoCurrent",
            $EaseeWallbox_reasonsForNoCurrent{ $d->{reasonForNoCurrent} } );

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
    EaseeWallbox_RefreshData($hash);
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

    my $readTemplate = $EaseeWallbox_urls{"getCurrentSession"};
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

    my $readTemplate = $EaseeWallbox_urls{"getChargerState"};
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


=end html

=cut
