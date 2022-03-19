package FHEM::EaseeWallbox;
use GPUtils qw(GP_Import GP_Export);

use strict;
use warnings;
use Data::Dumper;
use utf8;
use Encode qw( encode_utf8 );
use HttpUtils;
use JSON;

# try to use JSON::MaybeXS wrapper
#   for chance of better performance + open code
#eval {
#    require JSON::MaybeXS;
#    import JSON::MaybeXS qw( decode_json encode_json );
#    1;
#} or do {

    # try to use JSON wrapper
    #   for chance of better performance
 #   eval {
        # JSON preference order
 #       local $ENV{PERL_JSON_BACKEND} =
 #         'Cpanel::JSON::XS,JSON::XS,JSON::PP,JSON::backportPP'
 #         unless ( defined( $ENV{PERL_JSON_BACKEND} ) );

  #      require JSON;
  #      import JSON qw( decode_json encode_json );
  #      1;
  #  } or do {

        # In rare cases, Cpanel::JSON::XS may
        #   be installed but JSON|JSON::MaybeXS not ...
#        eval {
#            require Cpanel::JSON::XS;
#            import Cpanel::JSON::XS qw(decode_json encode_json);
#            1;
#        } or do {

            # In rare cases, JSON::XS may
            #   be installed but JSON not ...
 #           eval {
 #               require JSON::XS;
 #               import JSON::XS qw(decode_json encode_json);
 #               1;
 #           } or do {

                # Fallback to built-in JSON which SHOULD
                #   be available since 5.014 ...
 #               eval {
 #                   require JSON::PP;
 #                   import JSON::PP qw(decode_json encode_json);
 #                   1;
 #               } or do {

                    # Fallback to JSON::backportPP in really rare cases
 #                   require JSON::backportPP;
 #                   import JSON::backportPP qw(decode_json encode_json);
 #                   1;
 #               };
 #           };
 #       };
 #   };
#};

# Import von Funktionen und/oder Variablen aus der FHEM main
# man kann ::Funktionaname wählen und sich so den Import schenken. Variablen sollten aber
#   sauber importiert werden
use GPUtils qw(GP_Import);

## Import der FHEM Funktionen
#-- Run before package compilation
BEGIN {
    # Import from main context
    GP_Import(
        qw(
          readingFnAttributes
          Log3
          readingsBeginUpdate
          readingsEndUpdate
          readingsBulkUpdate
          readingsSingleUpdate
          InternalVal
          ReadingsVal
          RemoveInternalTimer
          InternalTimer
          HttpUtils_NonblockingGet
          HttpUtils_BlockingGet
          gettimeofday
          getUniqueId
          Attr
          )
    );
}

#-- Export to main context with different name
GP_Export(
    qw(
      Initialize
      )
);


my %gets = (
    update   => "noArg",
    health   => "noArg",
    charger => "noArg",
);

my %sets = (
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


## Datapoint, all behind API URI
my %dpoints = (
    getOAuthToken             => 'accounts/login',
    getRefreshToken           => 'accounts/refresh_token',
    getProfile                => 'accounts/profile',
    getChargingSession        => 'chargers/#ChargerID#/sessions/ongoing',
    getChargers               => 'accounts/chargers',
    getProducts               => 'accounts/products?userId=#UserId#',
    getChargerSite            => 'chargers/#ChargerID#/site',
    getChargerDetails         => 'chargers/#ChargerID#/details',
    getChargerConfiguration   => 'chargers/#ChargerID#/config',
    getChargerSessionsMonthly => 'sessions/charger/#ChargerID#/monthly',
    getChargerSessionsDaily   => 'sessions/charger/#ChargerID#/daily',
    getChargerState           => 'chargers/#ChargerID#/state',
    getCurrentSession         => 'chargers/#ChargerID#/sessions/ongoing',
    setCableLockState         => 'chargers/#ChargerID#/commands/lock_state',
    setReboot                 => 'chargers/#ChargerID#/commands/reboot',
    setUpdateFirmware         => 'chargers/#ChargerID#/commands/update_firmware',
    setEnableSmartCharging    => 'chargers/#ChargerID#/commands/smart_charging',
    setStartCharging          => 'chargers/#ChargerID#/commands/start_charging',
    setStopCharging           => 'chargers/#ChargerID#/commands/stop_charging',
    setPauseCharging          => 'chargers/#ChargerID#/commands/pause_charging',
    setResumeCharging         => 'chargers/#ChargerID#/commands/resume_charging',
    setToggleCharging         => 'chargers/#ChargerID#/commands/toggle_charging',
    setOverrideChargingSchedule =>     'chargers/#ChargerID#/commands/override_schedule',
    setPairRFIDTag             => 'chargers/#ChargerID#/commands/set_rfid_pairing_mode_async',
    changeChargerSettings      => 'chargers/#ChargerID#/settings',
    setChargingPrice           => 'sites/#SiteID#/price',
);
my %reasonsForNoCurrent = (
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
my %phaseModes = (
    1 => 'Locked to single phase',
    2 => 'Auto',
    3 => 'Locked to three phase',
);
my %operationModes = (
    1 => "Standby",
    2 => "Paused",
    3 => 'Charging',
    4 => 'Completed',
    5 => 'Error',
    6 => 'CarConnected'
);

#Private function to evaluate command-lists
# private funktionen beginnen immer mit _

#############################
sub _GetCmdList {
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

sub Initialize {
    my ($hash) = @_;

    $hash->{DefFn}   = \&Define;
    $hash->{UndefFn} = \&Undef;
    $hash->{SetFn}   = \&Set;
    $hash->{GetFn}   = \&Get;
    $hash->{AttrFn}  = \&Attr;
    $hash->{ReadFn}  = \&Read;
    $hash->{WriteFn} = \&Write;

    $hash->{AttrList} =
        'expertMode:yes,no '
      . 'ledStuff:yes,no '
      . 'SmartCharging:true,false '
      . $readingFnAttributes;

    #Log3, 'EaseeWallbox', 3, "EaseeWallbox module initialized.";
    return;  
}

sub Define {
    my ( $hash, $def ) = @_;
    my @param = split( "[ \t]+", $def );
    my $name  = $hash->{NAME};

    # set API URI as Internal Key
    $hash->{APIURI} = 'https://api.easee.cloud/api/';

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
    my $password = _encrypt( $param[3] );

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
    WriteToCloudAPI($hash, 'getChargers', 'GET');

    Log3 $name, 1, sprintf("EaseeWallbox_Define %s: Starting timer with interval %s", $name, InternalVal($name,'INTERVAL', undef));
    InternalTimer(gettimeofday()+ InternalVal($name,'INTERVAL', undef), "FHEM::EaseeWallbox::UpdateDueToTimer", $hash) if (defined $hash);
    return undef;
}

sub Undef {
    my ( $hash, $arg ) = @_;

    RemoveInternalTimer($hash);
    return undef;
}

sub Get {
    my ( $hash, $name, @args ) = @_;

    return '"get EaseeWallbox" needs at least one argument'
        if ( int(@args) < 1 );

    my $opt = shift @args;

    #create response, if cmd is wrong or gui asks
    my $cmdTemp = _GetCmdList( $hash, $opt, \%gets );
    return $cmdTemp if ( defined($cmdTemp) );

    $hash->{LOCAL} = 1;
    WriteToCloudAPI($hash, 'getChargers', 'GET')         if $opt eq "charger";
    RefreshData($hash)                                   if $opt eq "update";      
    delete $hash->{LOCAL};
    return undef;  
}

sub Set {
    my ( $hash, $name, @param ) = @_;

    return '"set $name" needs at least one argument' if ( int(@param) < 1 );

    my $opt   = shift @param;
    my $value = join( "", @param );

    #create response, if cmd is wrong or gui asks
    my $cmdTemp = _GetCmdList( $hash, $opt, \%sets );
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
        RefreshData($hash);
        delete $hash->{LOCAL};      
        InternalTimer(gettimeofday()+ InternalVal($name,'INTERVAL', undef), "FHEM::EaseeWallbox::UpdateDueToTimer", $hash);
        readingsSingleUpdate($hash,'state','Started',0);  
        Log3 $name, 1, sprintf("EaseeWallbox_Set %s: Updated readings and started timer to automatically update readings with interval %s", $name, InternalVal($name,'INTERVAL', undef));
    }
    elsif ( $opt eq "interval" ) {
        my $interval = shift @param;

        $interval = 60 unless defined($interval);
        if ( $interval < 5 ) { $interval = 5; }

        Log3 $name, 1, "EaseeWallbox_Set $name: Set interval to" . $interval;
        $hash->{INTERVAL} = $interval;
    }
     elsif ( $opt eq "cableLock" ) {
        my %message;
        $message{'state'} = $value;
        WriteToCloudAPI($hash, 'setCableLockState', 'POST', \%message)
    } 
    elsif ( $opt eq "pricePerKWH" ) {
         my %message;
        $message{'currencyId'} = "EUR";
        $message{'vat'}        = "19";
        $message{'costPerKWh'} = shift @param;
        WriteToCloudAPI($hash, 'setChargingPrice', 'POST', \%message)
    } 
    else 
    {
        $hash->{LOCAL} = 1;
        WriteToCloudAPI($hash, 'setStartCharging', 'POST')         if $opt eq "startCharging";
        WriteToCloudAPI($hash, 'setStopCharging', 'POST')          if $opt eq 'stopCharging';  
        WriteToCloudAPI($hash, 'setPauseCharging', 'POST')         if $opt eq 'pauseCharging';
        WriteToCloudAPI($hash, 'setResumeCharging', 'POST')        if $opt eq 'resumeCharging';
        WriteToCloudAPI($hash, 'setToggleCharging', 'POST')        if $opt eq 'toggleCharging';      
        WriteToCloudAPI($hash, 'setUpdateFirmware', 'POST')        if $opt eq 'updateFirmware';
        WriteToCloudAPI($hash, 'setOverrideChargingSchedule', 'POST')        if $opt eq 'overrideChargingSchedule';
        WriteToCloudAPI($hash, 'setPairRFIDTag', 'POST')           if $opt eq 'pairRfidTag';     
        WriteToCloudAPI($hash, 'setReboot', 'POST')                                   if $opt eq 'reboot';
        WriteToCloudAPI($hash, 'tobedone', 'POST')                                    if $opt eq 'enableSmartCharging';
        _loadToken($hash)                                                            if $opt eq 'refreshToken';   
        delete $hash->{LOCAL};
    }
    readingsSingleUpdate( $hash, 'state', 'Initialized', 0 );
    return undef;
}

sub Attr {
    my ( $cmd, $name, $attrName, $attrVal ) = @_;
    return;
}

sub RefreshData{
    my $hash     = shift;    
    my $name     = $hash->{NAME};
    WriteToCloudAPI($hash, 'getChargerSite', 'GET');
    WriteToCloudAPI($hash, 'getChargerState', 'GET');
    WriteToCloudAPI($hash, 'getCurrentSession', 'GET');
}

sub UpdateDueToTimer($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    #local allows call of function without adding new timer.
    #must be set before call ($hash->{LOCAL} = 1) and removed after (delete $hash->{LOCAL};)
    if ( !$hash->{LOCAL} ) {
        RemoveInternalTimer($hash);
        #Log3 "Test", 1, Dumper($hash);
        InternalTimer(
            gettimeofday() + InternalVal( $name, 'INTERVAL', undef ), "FHEM::EaseeWallbox::UpdateDueToTimer", $hash );
    }
    RefreshData($hash);
}

sub WriteToCloudAPI {
    my $hash   = shift;
    my $dpoint = shift;
    my $method = shift;    
    my $message = shift;
    my $name = $hash->{NAME};
    my $url = $hash->{APIURI} . $dpoints{$dpoint};

    #########
    # CHANGE THIS
    my $payload;
    $payload  = encode_json \%$message if defined $message;
    my $deviceId = "WC1";

   if ( not defined $hash ) {
        my $msg = "Error on EaseeWallbox_WriteToCloudAPI. Missing hash variable";
        Log3 'EaseeWallbox', 1, $msg;
        return $msg;
    }

    #Check if chargerID is required in URL and replace or alert.
    if ( $url =~ m/#ChargerID#/ ) {
        my $chargerId = ReadingsVal( $name, 'charger_id', undef );
        if ( not defined $chargerId ) {
            my $error = "Error on EaseeWallbox_WriteToCloudAPI. Missing charger_id. Please ensure basic data is available.";
            Log3 'EaseeWallbox', 1, $error;
            return $error;
        }
        $url =~ s/#ChargerID#/$chargerId/g;
    }

    #Check if siteID is required in URL and replace or alert.
    if ( $url =~ m/#SiteID#/ ) {
        my $siteId = ReadingsVal( $name, 'site_id', undef );
        if ( not defined $siteId ) {
            my $error = "Error on EaseeWallbox_WriteToCloudAPI. Missing site_id. Please ensure basic data is available.";
            Log3 'EaseeWallbox', 1, $error;
            return $error;
        }
        $url =~ s/#SiteID#/$siteId/g;         
    }

    my $CurrentTokenData = _loadToken($hash);
    my $header = 
        {
            "Content-Type"  => "application/json;charset=UTF-8",
            "Authorization" =>
                "$CurrentTokenData->{'tokenType'} $CurrentTokenData->{'accessToken'}"
        };

    # $method ist GET oder POST
    # bei POST ist $payload gleich data

    HttpUtils_NonblockingGet(
        {
            url                => $url,
            timeout            => 15,
            incrementalTimeout => 1,
            hash               => $hash,
            dpoint             => $dpoint,
            device_id          => $deviceId,
            data               => $payload,
            method             => $method,
            header             => $header,
            callback           => \&ResponseHandling
        }
    );
    return;
}

sub ResponseHandling {
    my $param = shift;
    my $err   = shift;
    my $data  = shift;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    Log3 $name, 4, "Callback received." . $param->{url};

    if ( $err ne "" )   # wenn ein Fehler bei der HTTP Abfrage aufgetreten ist
    {
        Log3 $name, 3,"error while requesting ". $param->{url}. " - $err";    # Eintrag fürs Log
        readingsSingleUpdate( $hash, "lastResponse", "ERROR $err", 1 );
        return undef;
    }

    my $code = $param->{code};
    if ($code >= 400){
        Log3 $name, 3,"HTTPS error while requesting ". $param->{url}. " - $code";    # Eintrag fürs Log
        readingsSingleUpdate( $hash, "lastResponse", "ERROR: HTTP Code $code", 1 );
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
  
    my $d;
    eval {
        my $d = decode_json($data);
        Log3 $name, 5, 'Decoded: ' . Dumper($d);
        if ( defined $d and $d ne '') {

            if($param->{dpoint} eq 'getChargers')
            {
                my $site    = $d->[0];
                my $circuit = $site->{circuits}->[0];
                my $charger = $circuit->{chargers}->[0];

                readingsBeginUpdate($hash);
                my $chargerId = $charger->{id};
                readingsBulkUpdate( $hash, "site_id",   $site->{id} );                
                readingsBulkUpdate( $hash, "charger_id",   $chargerId );
                readingsBulkUpdate( $hash, "charger_name", $charger->{name} );
                readingsBulkUpdate( $hash, "lastResponse", 'OK - getReaders', 1);
                readingsEndUpdate( $hash, 1 );
                WriteToCloudAPI($hash, 'getChargerConfiguration', 'GET');
                return;
            }

            if($param->{dpoint} eq 'getChargerConfiguration')
            {
                readingsBeginUpdate($hash);
                readingsBulkUpdate( $hash, "charger_isEnabled", $d->{isEnabled} );
                readingsBulkUpdate( $hash, "lockCablePermanently", $d->{lockCablePermanently} );
                readingsBulkUpdate($hash, "authorizationRequired", $d->{authorizationRequired});
                readingsBulkUpdate( $hash, "remoteStartRequired", $d->{remoteStartRequired} );
                readingsBulkUpdate( $hash, "smartButtonEnabled", $d->{smartButtonEnabled} );
                readingsBulkUpdate( $hash, "wiFiSSID", $d->{wiFiSSID} );
                readingsBulkUpdate( $hash, "charger_phaseModeId", $d->{phaseMode} );
                readingsBulkUpdate( $hash, "charger_phaseMode",$phaseModes{ $d->{phaseMode} } );
                readingsBulkUpdate($hash, "localAuthorizationRequired",$d->{localAuthorizationRequired});        
                readingsBulkUpdate( $hash, "maxChargerCurrent", $d->{maxChargerCurrent} );
                readingsBulkUpdate( $hash, "ledStripBrightness", $d->{ledStripBrightness} );
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

                #readingsBulkUpdate( $hash, "charger_localNodeType",
                #    $d->{localNodeType} );

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
                #readingsBulkUpdate( $hash, "chargingSchedule",
                #    $d->{chargingSchedule} );
                readingsBulkUpdate( $hash, "lastResponse", 'OK - getChargerConfig', 1);
                readingsEndUpdate( $hash, 1 );
                return undef;
            }

            if($param->{dpoint} eq 'getCurrentSession')
            {
                readingsBeginUpdate($hash);
                readingsBulkUpdate( $hash, "session_energy", $d->{sessionEnergy} );
                readingsBulkUpdate( $hash, "session_start",  $d->{sessionStart} );
                readingsBulkUpdate( $hash, "session_end",    $d->{sessionEnd} );
                readingsBulkUpdate( $hash, "session_chargeDurationInSeconds", $d->{chargeDurationInSeconds} );
                readingsBulkUpdate( $hash, "session_firstEnergyTransfer",$d->{firstEnergyTransferPeriodStart} );
                readingsBulkUpdate( $hash, "session_lastEnergyTransfer", $d->{lastEnergyTransferPeriodStart} );
                readingsBulkUpdate( $hash, "session_pricePerKWH", $d->{pricePrKwhIncludingVat} );
                readingsBulkUpdate( $hash, "session_chargingCost", $d->{costIncludingVat} );
                readingsBulkUpdate( $hash, "session_id", $d->{sessionId} );
                readingsBulkUpdate( $hash, "lastResponse", 'OK - getCurrentSession', 1);
                readingsEndUpdate( $hash, 1 );
                return undef;
            }

            if($param->{dpoint} eq 'getChargerSite')
            {
                readingsBeginUpdate($hash);
                readingsBulkUpdate( $hash, "site_key",    $d->{siteKey} );
                readingsBulkUpdate( $hash, "cost_perKWh", $d->{costPerKWh} );
                readingsBulkUpdate( $hash, "cost_perKwhExcludeVat", $d->{costPerKwhExcludeVat} );
                readingsBulkUpdate( $hash, "cost_vat",          $d->{vat} );
                readingsBulkUpdate( $hash, "cost_currency",     $d->{currencyId} );
                #readingsBulkUpdate( $hash, "site_ratedCurrent", $d->{ratedCurrent} );
                #readingsBulkUpdate( $hash, "site_createdOn",    $d->{createdOn} );
                #readingsBulkUpdate( $hash, "site_updatedOn",    $d->{updatedOn} );
                readingsBulkUpdate( $hash, "lastResponse", 'OK - getChargerSite', 1);
                readingsEndUpdate( $hash, 1 );
                return undef;            
            }

            if($param->{dpoint} eq 'getChargerState')
            {
                readingsBeginUpdate($hash);
                readingsBulkUpdate( $hash, "operationModeCode", $d->{chargerOpMode} );
                readingsBulkUpdate( $hash, "operationMode", $operationModes{ $d->{chargerOpMode} } );
                readingsBulkUpdate( $hash, "power", $d->{totalPower} );
                readingsBulkUpdate( $hash, "kWhInSession", $d->{sessionEnergy} );
                readingsBulkUpdate( $hash, "phase",       $d->{outputPhase} );
                readingsBulkUpdate( $hash, "latestPulse", $d->{latestPulse} );
                readingsBulkUpdate( $hash, "current", $d->{outputCurrent} );
                readingsBulkUpdate( $hash, "dynamicCurrent", $d->{dynamicChargerCurrent} );
                readingsBulkUpdate( $hash, "reasonCodeForNoCurrent", $d->{reasonForNoCurrent} );
                readingsBulkUpdate( $hash, "reasonForNoCurrent", $reasonsForNoCurrent{ $d->{reasonForNoCurrent} } );
                readingsBulkUpdate( $hash, "errorCode",      $d->{errorCode} );
                readingsBulkUpdate( $hash, "fatalErrorCode", $d->{fatalErrorCode} );
                readingsBulkUpdate( $hash, "lifetimeEnergy", $d->{lifetimeEnergy} );
                readingsBulkUpdate( $hash, "online",         $d->{isOnline} );
                readingsBulkUpdate( $hash, "voltage",        $d->{voltage} );
                readingsBulkUpdate( $hash, "wifi_rssi",      $d->{wiFiRSSI} );
                readingsBulkUpdate( $hash, "wifi_apEnabled", $d->{wiFiAPEnabled} );
                readingsBulkUpdate( $hash, "cell_rssi",      $d->{cellRSSI} );
                readingsBulkUpdate( $hash, "lastResponse", 'OK - getChargerState', 1);
                readingsEndUpdate( $hash, 1 );
                return undef;            
            }

            readingsSingleUpdate( $hash, "lastResponse", 'OK - Action '. $d->{commandId}, 1 )       if defined $d->{commandId};
            readingsSingleUpdate( $hash, "lastResponse", 'ERROR: '. $d->{title}.' ('.$d->{status}.')', 1 )     if defined $d->{status} and defined $d->{title};
            return undef;
        }  else {
            readingsSingleUpdate( $hash, "lastResponse", 'OK - empty', 1);
            return undef;
        }
    };
    if ($@) {
        readingsSingleUpdate( $hash, "lastResponse", 'ERROR while deconding response: '. $@, 1 );
        Log3 $name, 5, 'Failure decoding: ' . $@;
    } 

    return;
}


sub _loadToken {
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
        $Token = _newTokenRequest($hash);
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
            $Token = _tokenRefresh($hash);
        }
    }
    return $Token if $Token;
}

sub _newTokenRequest {
    my $hash = shift;
    my $name = $hash->{NAME};
    my $password
        = _decrypt( InternalVal( $name, 'Password', undef ) );
    my $username = InternalVal( $name, 'Username', undef );

    Log3 $name, 5, "EaseeWallbox $name" . ": " . "calling NewTokenRequest()";

    my $data = {
        userName => $username,
        password => $password,
    };

    my $param = {
        url     => $hash->{APIURI} . $dpoints{getOAuthToken},
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

sub _tokenRefresh {
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
        url     => $hash->{APIURI} . $dpoints{getRefreshToken},
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

sub _encrypt($) {
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

sub _decrypt($) {
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
