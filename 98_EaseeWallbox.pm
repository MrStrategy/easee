package FHEM::EaseeWallbox;

use strict;
use warnings;
use Data::Dumper;
use utf8;
use Encode qw( encode_utf8 );
use HttpUtils;
use JSON;
use DateTime;
use DateTime::Format::Strptime;
use List::Util qw(min);

# try to use JSON::MaybeXS wrapper
#   for chance of better performance + open code
eval {
    require JSON::MaybeXS;
    import JSON::MaybeXS qw( decode_json encode_json );
    1;
} or do {

    # try to use JSON wrapper
    #   for chance of better performance
    eval {
        # JSON preference order
        local $ENV{PERL_JSON_BACKEND} =
          'Cpanel::JSON::XS,JSON::XS,JSON::PP,JSON::backportPP'
          unless ( defined( $ENV{PERL_JSON_BACKEND} ) );

        require JSON;
        import JSON qw( decode_json encode_json );
        1;
    } or do {

        # In rare cases, Cpanel::JSON::XS may
        #   be installed but JSON|JSON::MaybeXS not ...
        eval {
            require Cpanel::JSON::XS;
            import Cpanel::JSON::XS qw(decode_json encode_json);
            1;
        } or do {

            # In rare cases, JSON::XS may
            #   be installed but JSON not ...
            eval {
                require JSON::XS;
                import JSON::XS qw(decode_json encode_json);
                1;
            } or do {

                # Fallback to built-in JSON which SHOULD
                #   be available since 5.014 ...
                eval {
                    require JSON::PP;
                    import JSON::PP qw(decode_json encode_json);
                    1;
                } or do {

                    # Fallback to JSON::backportPP in really rare cases
                    require JSON::backportPP;
                    import JSON::backportPP qw(decode_json encode_json);
                    1;
                };
            };
        };
    };
};

# Import von Funktionen und/oder Variablen aus der FHEM main
# man kann ::Funktionaname wählen und sich so den Import schenken. Variablen sollten aber
#   sauber importiert werden
use GPUtils qw(GP_Import GP_Export);

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
          readingsDelete
          InternalVal
          ReadingsVal
          RemoveInternalTimer
          InternalTimer
          HttpUtils_NonblockingGet
          HttpUtils_BlockingGet
          gettimeofday
          getUniqueId
          Attr
          defs
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
    update  => "noArg",
    charger => "noArg",
);

my %sets = (
    enabled                  => "",
    disabled                 => "",
    enableSmartButton        => "true,false",
    authorizationRequired    => "true,false",
    startCharging            => "",
    stopCharging             => "",
    pauseCharging            => "",
    resumeCharging           => "",
    toggleCharging           => "",
    refreshToken             => "noArg",
    cableLock                => "true,false",
    reboot                   => "noArg",
    updateFirmware           => "noArg",
    enableSmartCharging      => "true,false",
    ledStripBrightness       => "",
    overrideChargingSchedule => "",
    pairRfidTag              => "",
    pricePerKWH              => "",
    activateTimer            => "",
    deactivateTimer          => "",
    dynamicCurrent           => "",
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
    getDailyEnergyConsumption => 'chargers/lifetime-energy/#ChargerID#/daily',
    getMonthlyEnergyConsumption => 'chargers/lifetime-energy/#ChargerID#/monthly',
    getDynamicCurrent         => 'sites/#SiteID#/circuits/#CircuitId#/dynamicCurrent',
    setCableLockState         => 'chargers/#ChargerID#/commands/lock_state',
    setReboot                 => 'chargers/#ChargerID#/commands/reboot',
    setUpdateFirmware         => 'chargers/#ChargerID#/commands/update_firmware',
    setEnableSmartCharging    => 'chargers/#ChargerID#/commands/smart_charging',
    setStartCharging       => 'chargers/#ChargerID#/commands/start_charging',
    setStopCharging        => 'chargers/#ChargerID#/commands/stop_charging',
    setPauseCharging       => 'chargers/#ChargerID#/commands/pause_charging',
    setResumeCharging      => 'chargers/#ChargerID#/commands/resume_charging',
    setToggleCharging      => 'chargers/#ChargerID#/commands/toggle_charging',
    setOverrideChargingSchedule =>
      'chargers/#ChargerID#/commands/override_schedule',
    setPairRFIDTag =>
      'chargers/#ChargerID#/commands/set_rfid_pairing_mode_async',
    changeChargerSettings => 'chargers/#ChargerID#/settings',
    setChargingPrice      => 'sites/#SiteID#/price',
    setDynamicCurrent     => 'sites/#SiteID#/circuits/#CircuitId#/dynamicCurrent',
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
    7 => 'IllegalGridType',
    8 => 'PrimaryUnitHasNotReceivedCurrentRequestFromSecondaryUnit',
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
    0 => "Disconnected",
    1 => "Standby",
    2 => "Paused",
    3 => 'Charging',
    4 => 'Completed',
    5 => 'Error',
    6 => 'CarConnected'
);

my %commandCodes = (
    1  => "Reboot",
    2  => "Poll single observation",
    3  => "Poll all observations",
    4  => "Upgrade Firmware",
    5  => "Download settings",
    7  => "Scan Wifi",
    11 => "Set smart charging",
    23 => "Abort charging",
    25 => "Start Charging",
    26 => "Stop Charging",
    29 => "Set enabled",
    30 => "Set cable lock",
    11 => "Set smart charging",
    40 => "Set lightstripe brightness",
    43 => "Add keys",
    44 => "Clear keys",
    48 => "Pause/Resume/Toggle Charging",
    60 => "Add schedule",
    61 => "Cear Schedule",
    62 => "Get Schedule",
    63 => "Override Schedule",
    64 => "Purge Schedule",
    69 => "Set RFID Pairing Mode",
);

#Private function to evaluate command-lists
sub _GetCmdList {
    my ( $hash, $cmd, $commands ) = @_;
    my %cmdArray = %$commands;
    my $name     = $hash->{NAME};

    # return, if cmd is valid
    return if ( defined($cmd) and defined( $cmdArray{$cmd} ) );

    # response for gui or the user, if command is invalid
    my $retVal = join ' ',
      map {
          my $opt = $cmdArray{$_};
          ( defined($opt) and length($opt) ) ? "$_:$opt" : $_;
      } keys %cmdArray;

    return "error while parsing set-table" if ( !defined($retVal) or $retVal eq '' );
    return "Unknown argument $cmd, choose one of $retVal";
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
      . 'interval '
      . 'SmartCharging:true,false '
      . $readingFnAttributes;

    #Log3, 'EaseeWallbox', 2, "EaseeWallbox module initialized.";
    return;
}

sub Define {
    my ( $hash, $def ) = @_;
    my @param = split( "[ \t]+", $def );
    my $name  = $hash->{NAME};
    my $errmsg = '';

    # set API URI as Internal Key
    $hash->{APIURI} = 'https://api.easee.cloud/api/';
    Log3 $name, 3, "EaseeWallbox_Define $name: called ";


    # Check parameter(s) - Must be min 4 in total (counts strings not purly parameter, interval is optional)
    if ( int(@param) < 4 ) {
        $errmsg =
          "syntax error: define <name> EaseeWallbox <username> <password> [interval] [chargerID]";
        Log3 $name, 1, "EaseeWallbox $name: " . $errmsg;
        return $errmsg;
    }

    #Check if the username is an email address
    if ( $param[2] =~ /^.+@.+$/x )
    { # Regular expression without "/x" flag. See page 236 of PBP (RegularExpressions::RequireExtendedFormatting)
        my $username = $param[2];
        $hash->{Username} = $username;
    }
    else {
        $errmsg =
            "specify valid email address within the field username. Format: define <name> EaseeWallbox <username> <password> [interval]  [chargerID]";
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
        if ( $param[4] =~ /^\d+$/x )
        { # Regular expression without "/x" flag. See page 236 of PBP (RegularExpressions::RequireExtendedFormatting)
            $interval = $param[4];
        }
        else {
            $errmsg =
"Specify valid integer value for interval. Whole numbers > 5 only. Format: define <name> EaseeWallbox <username> <password> [interval]  [chargerID]";
            Log3 $name, 1, "EaseeWallbox $name: " . $errmsg;
            return $errmsg;
        }
    }

    if ( $interval < 5 ) { $interval = 5; }
    $hash->{INTERVAL} = $interval;

    $hash->{FIXED_CHARGER_ID} = $param[5] if defined $param[5];

    readingsSingleUpdate( $hash, 'state', 'Undefined', 0 );

    #Initial load of data
    WriteToCloudAPI( $hash, 'getChargers', 'GET' );

    Log3 $name, 2,
      sprintf( "EaseeWallbox_Define %s: Starting timer with interval %s",
        $name, InternalVal( $name, 'INTERVAL', undef ) );
    InternalTimer( gettimeofday() + InternalVal( $name, 'INTERVAL', undef ),
        "FHEM::EaseeWallbox::UpdateDueToTimer", $hash )
      if ( defined $hash );

    return;
}

sub Undef {
    my ( $hash, $arg ) = @_;
    RemoveInternalTimer($hash);
    return;
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
    WriteToCloudAPI( $hash, 'getChargers', 'GET' ) if $opt eq "charger";
    RefreshData($hash)                             if $opt eq "update";
    delete $hash->{LOCAL};
    return;
}

sub Set {
    my ( $hash, $name, @param ) = @_;

    return '"set $name" needs at least one argument' if ( int(@param) < 1 );

    my $opt = shift @param;
    my $value = join( "", @param );
    my %message;

    #create response, if cmd is wrong or gui asks
    my $cmdTemp = _GetCmdList( $hash, $opt, \%sets );
    return $cmdTemp if ( defined($cmdTemp) );

    if ( $opt eq "deactivateTimer" ) {

# Cascading if-elsif chain. See pages 117,118 of PBP (ControlStructures::ProhibitCascadingIfElse) kann man anders machen. Später machen wir das
        RemoveInternalTimer($hash);
        Log3 $name, 3,
"EaseeWallbox_Set $name: Stopped the timer to automatically update readings";
        readingsSingleUpdate( $hash, 'state', 'Initialized', 0 );
        return;
    }
    elsif ( $opt eq "activateTimer" ) {

        #Update once manually and then start the timer
        RemoveInternalTimer($hash);
        $hash->{LOCAL} = 1;
        RefreshData($hash);
        delete $hash->{LOCAL};
        InternalTimer( gettimeofday() + InternalVal( $name, 'INTERVAL', undef ),
            "FHEM::EaseeWallbox::UpdateDueToTimer", $hash );
        readingsSingleUpdate( $hash, 'state', 'Started', 0 );
        Log3 $name, 3,
          sprintf(
"EaseeWallbox_Set %s: Updated readings and started timer to automatically update readings with interval %s",
            $name, InternalVal( $name, 'INTERVAL', undef ) );
    }
    elsif ( $opt eq "cableLock" ) {

        $message{'state'} = $value;
        WriteToCloudAPI( $hash, 'setCableLockState', 'POST', \%message );
    }
    elsif ( $opt eq "pricePerKWH" ) {

        $message{'currencyId'} = "EUR";
        $message{'vat'}        =  19;
        $message{'costPerKWh'} = shift @param;
        WriteToCloudAPI( $hash, 'setChargingPrice', 'POST', \%message );
    }
    elsif ( $opt eq "pairRfidTag" ) {
        my $timeout = shift @param;

      #if (defined $timeout and /^\d+$/)         { print "is a whole number\n" }
        $timeout = '60' if not defined $timeout or $timeout = '';

        $message{'timeout'} = "60";
        WriteToCloudAPI( $hash, 'setPairRFIDTag', 'POST', \%message );
    }
    elsif ( $opt eq "enableSmartCharging" ) {

        $message{'smartCharging'} = shift @param;
        WriteToCloudAPI( $hash, 'changeChargerSettings', 'POST', \%message );
    }
    elsif ( $opt eq "enabled" ) {

        $message{'enabled'} = "true";
        WriteToCloudAPI( $hash, 'changeChargerSettings', 'POST', \%message );
    }
    elsif ( $opt eq "disabled" ) {

        $message{'enabled'} = "false";
        WriteToCloudAPI( $hash, 'changeChargerSettings', 'POST', \%message );
    }
    elsif ( $opt eq "authorizationRequired" ) {

        $message{'authorizationRequired'} = shift @param;
        WriteToCloudAPI( $hash, 'changeChargerSettings', 'POST', \%message );
    }
    elsif ( $opt eq "enableSmartButton" ) {

        $message{'smartButtonEnabled'} = shift @param;
        WriteToCloudAPI( $hash, 'changeChargerSettings', 'POST', \%message );
    }
    elsif ( $opt eq "ledStripBrightness" ) {

        $message{'ledStripBrightness'} = shift @param;
        WriteToCloudAPI( $hash, 'changeChargerSettings', 'POST', \%message );
    }
    elsif ( $opt eq "dynamicCurrent" ) {

        $message{'phase1'} = shift @param;
        $message{'phase2'} = shift @param;
        $message{'phase3'} = shift @param;
        my $ttl = shift @param;
        $message{'timeToLive'} = ( defined $ttl and $ttl ne '' ? $ttl : 0);
        WriteToCloudAPI( $hash, 'setDynamicCurrent', 'POST', \%message );
    }
    else {
        $hash->{LOCAL} = 1;
        WriteToCloudAPI( $hash, 'setStartCharging', 'POST' )
          if $opt eq "startCharging";
        WriteToCloudAPI( $hash, 'setStopCharging', 'POST' )
          if $opt eq 'stopCharging';
        WriteToCloudAPI( $hash, 'setPauseCharging', 'POST' )
          if $opt eq 'pauseCharging';
        WriteToCloudAPI( $hash, 'setResumeCharging', 'POST' )
          if $opt eq 'resumeCharging';
        WriteToCloudAPI( $hash, 'setToggleCharging', 'POST' )
          if $opt eq 'toggleCharging';
        WriteToCloudAPI( $hash, 'setUpdateFirmware', 'POST' )
          if $opt eq 'updateFirmware';
        WriteToCloudAPI( $hash, 'setOverrideChargingSchedule', 'POST' )
          if $opt eq 'overrideChargingSchedule';
        WriteToCloudAPI( $hash, 'setReboot', 'POST' ) if $opt eq 'reboot';
        _loadToken($hash)                             if $opt eq 'refreshToken';
        delete $hash->{LOCAL};
    }
    readingsSingleUpdate( $hash, 'state', 'Initialized', 0 )
      ; # Die Modulinstanz ist doch nicht erst bei einem set Initialized, das ist doch schon nach dem define. Wenn dann ist hier ein status ala "processing setter" oder so.
    return;
}

sub Attr {
    my ( $cmd, $name, $attrName, $attrVal ) = @_;
    my $hash = $defs{$name};

    if ( $attrName eq 'interval' ) {
        if ( $cmd eq 'set' ) {
            return 'Interval must be greater than 0'
              if ( $attrVal == 0 );
            RemoveInternalTimer( $hash,
                "FHEM::EaseeWallbox::UpdateDueToTimer" );
            $hash->{INTERVAL} = $attrVal;
            InternalTimer( gettimeofday() + $hash->{INTERVAL},
                "FHEM::EaseeWallbox::UpdateDueToTimer", $hash );
            Log3 $name, 3,
              "EaseeWallbox ($name) - set interval: $attrVal";
        }
        elsif ( $cmd eq 'del' ) {
            RemoveInternalTimer( $hash,
                "FHEM::EaseeWallbox::UpdateDueToTimer" );
            $hash->{INTERVAL} = 60;
            InternalTimer( gettimeofday() + $hash->{INTERVAL},
                "FHEM::EaseeWallbox::UpdateDueToTimer", $hash );
            Log3 $name, 3,
"EaseeWallbox ($name) - delete interval and set default: 60";
        }
    }
    # hier kannst Du das setzen des Intervals umsetzen
    return;
}

sub RefreshData {
    my $hash = shift;
    my $name = $hash->{NAME};

    WriteToCloudAPI( $hash, 'getChargerSite',            'GET' );
    WriteToCloudAPI( $hash, 'getChargerState',           'GET' );
    WriteToCloudAPI( $hash, 'getChargerConfiguration',   'GET' );
    WriteToCloudAPI( $hash, 'getDynamicCurrent',         'GET' );

    #Rate Limit. Just run every 6 minutes
    if ($hash->{CURRENT_SESSION_REFRESH} + 360 < gettimeofday()) {
        WriteToCloudAPI( $hash, 'getCurrentSession',         'GET' );
        WriteToCloudAPI( $hash, 'getMonthlyEnergyConsumption', 'GET' );
        WriteToCloudAPI( $hash, 'getDailyEnergyConsumption',   'GET' );
    }

    return;    # immer mit einem return eine funktion beenden
}

sub UpdateDueToTimer {
    my ($hash) = @_;
    my $name = $hash->{NAME};

#local allows call of function without adding new timer.
#must be set before call ($hash->{LOCAL} = 1) and removed after (delete $hash->{LOCAL};)
    if ( !$hash->{LOCAL} ) {
        RemoveInternalTimer($hash);

        InternalTimer( gettimeofday() + InternalVal( $name, 'INTERVAL', undef ),
            "FHEM::EaseeWallbox::UpdateDueToTimer", $hash );
    }
    return RefreshData($hash);
}

sub WriteToCloudAPI {
    my $hash    = shift;
    my $dpoint  = shift;
    my $method  = shift;
    my $message = shift;
    my $name    = $hash->{NAME};
    my $url     = $hash->{APIURI} . $dpoints{$dpoint};
    my $chargerId;
    my $siteId;
    my $payload;
    my $circuitId;

    #########
    # CHANGE THIS
     my $deviceId = "WC1";
    $payload = encode_json \%$message if defined $message;

    if ( not defined $hash ) {
        my $msg =
          "Error on EaseeWallbox_WriteToCloudAPI. Missing hash variable";
        Log3 'EaseeWallbox', 1, $msg;
        return $msg;
    }

    #Check if chargerID is required in URL and replace or alert.
    if ( $url =~ m/\#ChargerID\#/x )
    {
        #If defined, prefer the fixed charger id over the reading.
        $chargerId = InternalVal( $name, 'FIXED_CHARGER_ID', undef );
        $chargerId = ReadingsVal( $name, 'charger_id', undef )      if not defined $chargerId;
        if ( not defined $chargerId ) {
            my $error =
"Error on EaseeWallbox_WriteToCloudAPI. Missing charger_id. Please ensure basic data is available.";
            Log3 'EaseeWallbox', 1, $error;
            return $error;
        }
        $url =~ s/\#ChargerID\#/$chargerId/xg
          ; # Regular expression without "/x" flag. See page 236 of PBP (RegularExpressions::RequireExtendedFormatting)
    }

    #Check if siteID is required in URL and replace or alert.
    if ( $url =~ m/\#SiteID\#/x )
    { # Regular expression without "/x" flag. See page 236 of PBP (RegularExpressions::RequireExtendedFormatting)
        $siteId = ReadingsVal( $name, 'site_id', undef );
        if ( not defined $siteId ) {
            my $error =
"Error on EaseeWallbox_WriteToCloudAPI. Missing site_id. Please ensure basic data is available.";
            Log3 'EaseeWallbox', 1, $error;
            return $error;
        }
        $url =~ s/\#SiteID\#/$siteId/xg
          ; # Regular expression without "/x" flag. See page 236 of PBP (RegularExpressions::RequireExtendedFormatting)
    }


    #Check if CircuitId is required in URL and replace or alert.
    if ( $url =~ m/\#CircuitId\#/x )
    { # Regular expression without "/x" flag. See page 236 of PBP (RegularExpressions::RequireExtendedFormatting)
        $circuitId = ReadingsVal( $name, 'circuit_id', undef );
        if ( not defined $circuitId ) {
            my $error =
"Error on EaseeWallbox_WriteToCloudAPI. Missing circuit_id. Please ensure basic data is available.";
            Log3 'EaseeWallbox', 1, $error;
            return $error;
        }
        $url =~ s/\#CircuitId\#/$circuitId/xg
          ; # Regular expression without "/x" flag. See page 236 of PBP (RegularExpressions::RequireExtendedFormatting)
    }


    my $CurrentTokenData = _loadToken($hash);
    my $header           = {
        "Content-Type" => "application/json;charset=UTF-8",
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
    my $hash  = $param->{hash};
    my $name  = $hash->{NAME};
    my $decoded_json;
    my $value;

    Log3 $name, 4, "Callback received. " . $param->{url};

    if ( $err ne "" )    # wenn ein Fehler bei der HTTP Abfrage aufgetreten ist
    {
        Log3 $name, 1,
            "error while requesting "
          . $param->{url}
          . " - $err";    # Eintrag fürs Log
        readingsSingleUpdate( $hash, "lastResponse", "ERROR $err", 1 );
        return;
    }

    my $code = $param->{code};

    if ( $param->{dpoint} eq 'getCurrentSession' ) {

        $hash->{CURRENT_SESSION_REFRESH} = gettimeofday();

        if ( $code == 404  )
        {
            readingsDelete( $hash, 'session_energy' );
            readingsDelete( $hash, 'session_start' );
            readingsDelete( $hash, 'session_end' );
            readingsDelete( $hash, 'session_chargeDurationInSeconds' );
            readingsDelete( $hash, 'session_firstEnergyTransfer' );
            readingsDelete( $hash, 'session_lastEnergyTransfer' );
            readingsDelete( $hash, 'session_pricePerKWH' );
            readingsDelete( $hash, 'session_chargingCost' );
            readingsDelete( $hash, 'session_id' );
            return;
        }
    }


    if ( $code == 429 ) {
        Log3 $name, 2,
            "Too many requests while requesting "
          . $param->{url}
          . " - $code. Most reporting services accept 10 requests per 60 minutes."; 
    } elsif ( $code >= 400 ) {
        Log3 $name, 1,
            "HTTPS error while requesting "
          . $param->{url}
          . " - $code"; 
    }

    if ( $code >= 400 ) {
        my $method = $param->{dpoint};
        readingsSingleUpdate( $hash, "lastResponse", "ERROR: $method - HTTP Code $code", 1 );
        readingsSingleUpdate( $hash, "lastError", "$method: HTTP Code $code", 1 );    
        return;
    }

    Log3 $name, 4,
      "Received non-blocking data from EaseeWallbox.";

    Log3 $name, 4, "FHEM -> EaseeWallbox (url): " . $param->{url};
    Log3 $name, 5, "FHEM -> EaseeWallbox (method): " . $param->{method};
    Log3 $name, 4, "FHEM -> EaseeWallbox (payload): " . (defined $param->{data} and $param->{data} ne '' ? $param->{data} : '<empty>');
    Log3 $name, 4, "EaseeWallbox -> FHEM (resultCode): " . $code;
    Log3 $name, 4, "EaseeWallbox -> FHEM (payload): " . (defined $data and $data ne '' ? $data : '<empty>');
    Log3 $name, 5, 'EaseeWallbox -> FHEM (error): ' . (defined $err and $err ne '' ? $$err : '<empty>');


    eval { $decoded_json = decode_json($data) }; # statt eval ist es empfohlen catch try zu verwenden. Machen wir später

    Log3 $name, 5, 'Decoded Payload: ' . Dumper($decoded_json);
    if (    defined $decoded_json
        and $decoded_json ne ''
        and ref($decoded_json) eq "HASH"
        or ( ref($decoded_json) eq "ARRAY" and $decoded_json > 0 ) )
    {
        if ( $param->{dpoint} eq 'getChargers' ) {
            Processing_DpointGetChargers( $hash, $decoded_json );
            return;
        }

        if ( $param->{dpoint} eq 'getDailyEnergyConsumption' ) {
            Processing_DpointGetDailyEnergyConsumption( $hash, $decoded_json );
            return;
        }

        if ( $param->{dpoint} eq 'getMonthlyEnergyConsumption' ) {
            Processing_DpointGetMonthlyEnergyConsumption( $hash, $decoded_json );
            return;
        }

        if ( $param->{dpoint} eq 'getChargerConfiguration' ) {
            Processing_DpointGetChargerConfiguration( $hash, $decoded_json );
            return;
        }

        if ( $param->{dpoint} eq 'getCurrentSession' ) {
            Processing_DpointGetCurrentSession( $hash, $decoded_json );
            return;
        }

        if ( $param->{dpoint} eq 'getChargerSite' ) {
            Processing_DpointGetChargerSite( $hash, $decoded_json );
            return;
        }

        if ( $param->{dpoint} eq 'getChargerState' ) {
            Processing_DpointGetChargerState( $hash, $decoded_json );
            return;
        }

        if ( $param->{dpoint} eq 'getDynamicCurrent' ) {
            Processing_DpointGetDynamicCurrent( $hash, $decoded_json );
            return;
        }


        $decoded_json = $decoded_json->[0] if ref($decoded_json) eq "ARRAY";
        readingsSingleUpdate( $hash, "lastResponse",
            'OK - Action: ' . $commandCodes{ $decoded_json->{commandId} }, 1 )
          if exists $decoded_json->{commandId};
        readingsSingleUpdate(
            $hash,
            "lastResponse",
            'ERROR: '
              . $decoded_json->{title} . ' ('
              . $decoded_json->{status} . ')',
            1
          )
          if exists $decoded_json->{status} and exists $decoded_json->{title};
        return;
    }
    else {
        readingsSingleUpdate( $hash, "lastResponse", 'OK - empty (' . $param->{dpoint} . ')', 1 );
        return;
    }

    if ($@) {
        readingsSingleUpdate( $hash, "lastResponse",
            'ERROR while deconding response: ' . $@, 1 );
        Log3 $name, 5, 'Failure decoding: ' . $@;
    }

    return;
}

sub Processing_DpointGetCurrentSessionNotFound {
    my $hash         = shift;
    my $decoded_json = shift;

    my $name = $hash->{NAME};
    readingsBeginUpdate($hash);
    readingsBulkUpdate( $hash, 'session_energy', 'N/A' );
    readingsBulkUpdate( $hash, 'session_start', 'N/A' );
    readingsBulkUpdate( $hash, 'session_end', 'N/A' );
    readingsBulkUpdate( $hash, 'session_chargeDurationInSeconds', 'N/A' );
    readingsBulkUpdate( $hash, 'session_firstEnergyTransfer', 'N/A' );
    readingsBulkUpdate( $hash, 'session_lastEnergyTransfer', 'N/A' );
    readingsBulkUpdate( $hash, 'session_pricePerKWH', 'N/A' );
    readingsBulkUpdate( $hash, 'session_chargingCost', 'N/A' );
    readingsBulkUpdate( $hash, 'session_id', 'N/A' );
    readingsEndUpdate( $hash, 1 );
    return;
}


sub Processing_DpointGetChargerState {
    my $hash         = shift;
    my $decoded_json = shift;

    my $name = $hash->{NAME};

    readingsBeginUpdate($hash);
    readingsBulkUpdate( $hash, "operationModeCode",
        $decoded_json->{chargerOpMode} );
    readingsBulkUpdate( $hash, "operationMode",
        $operationModes{ $decoded_json->{chargerOpMode} } );
    readingsBulkUpdate( $hash, "power",
        sprintf( "%.2f", $decoded_json->{totalPower} ) );
    readingsBulkUpdate( $hash, "kWhInSession",
        sprintf( "%.2f", $decoded_json->{sessionEnergy} ) );
    readingsBulkUpdate( $hash, "phase", $decoded_json->{outputPhase} );
    readingsBulkUpdate( $hash, "latestPulse",
        _transcodeDate( $decoded_json->{latestPulse} ) );
    readingsBulkUpdate( $hash, "current",
        $decoded_json->{outputCurrent} );
    readingsBulkUpdate( $hash, "dynamicCurrent",
        $decoded_json->{dynamicChargerCurrent} );
    readingsBulkUpdate( $hash, "reasonCodeForNoCurrent",
        $decoded_json->{reasonForNoCurrent} );
    readingsBulkUpdate( $hash, "reasonForNoCurrent",
        $reasonsForNoCurrent{ $decoded_json->{reasonForNoCurrent} } );
    readingsBulkUpdate( $hash, "errorCode",
        $decoded_json->{errorCode} );
    readingsBulkUpdate( $hash, "fatalErrorCode",
        $decoded_json->{fatalErrorCode} );
    readingsBulkUpdate( $hash, "lifetimeEnergy",
        sprintf( "%.2f", $decoded_json->{lifetimeEnergy} ) );
    readingsBulkUpdate( $hash, "online",
        NumericToBoolean($decoded_json->{isOnline} ));
    readingsBulkUpdate( $hash, "voltage",
        sprintf( "%.2f", $decoded_json->{voltage} ) );
    readingsBulkUpdate( $hash, "wifi_rssi", $decoded_json->{wiFiRSSI} );
    readingsBulkUpdate( $hash, "wifi_apEnabled",
        NumericToBoolean($decoded_json->{wiFiAPEnabled} ));
    readingsBulkUpdate( $hash, "cell_rssi", $decoded_json->{cellRSSI} );
    readingsBulkUpdate( $hash, "lastResponse",
        'OK - getChargerState', 1 );
    readingsEndUpdate( $hash, 1 );
    return;
}

sub Processing_DpointGetChargerConfiguration {
    my $hash         = shift;
    my $decoded_json = shift;

    my $name = $hash->{NAME};
    readingsBeginUpdate($hash);
    readingsBulkUpdate( $hash, "isEnabled",
        NumericToBoolean($decoded_json->{isEnabled} ));
    readingsBulkUpdate( $hash, "isCablePermanentlyLocked",
        NumericToBoolean($decoded_json->{lockCablePermanently} ));
    readingsBulkUpdate( $hash, "isAuthorizationRequired",
        NumericToBoolean($decoded_json->{authorizationRequired}) );
    readingsBulkUpdate( $hash, "isRemoteStartRequired",
        NumericToBoolean($decoded_json->{remoteStartRequired}) );
    readingsBulkUpdate( $hash, "isSmartButtonEnabled",
        NumericToBoolean($decoded_json->{smartButtonEnabled}) );
    readingsBulkUpdate( $hash, "wiFiSSID", $decoded_json->{wiFiSSID} );
    readingsBulkUpdate( $hash, "phaseModeId",
        $decoded_json->{phaseMode} );
    readingsBulkUpdate( $hash, "phaseMode",
        $phaseModes{ $decoded_json->{phaseMode} } );
    readingsBulkUpdate(
        $hash,
        "isLocalAuthorizationRequired",
        NumericToBoolean($decoded_json->{localAuthorizationRequired}
    ));
    readingsBulkUpdate( $hash, "maxChargerCurrent",
        $decoded_json->{maxChargerCurrent} );
    readingsBulkUpdate( $hash, "ledStripBrightness",
        $decoded_json->{ledStripBrightness} );

    #readingsBulkUpdate( $hash, "charger_offlineChargingMode",
    #    $decoded_json->{offlineChargingMode} );
    #readingsBulkUpdate( $hash, "charger_circuitMaxCurrentP1",
    #    $decoded_json->{circuitMaxCurrentP1} );
    #readingsBulkUpdate( $hash, "charger_circuitMaxCurrentP2",
    #    $decoded_json->{circuitMaxCurrentP2} );
    #readingsBulkUpdate( $hash, "charger_circuitMaxCurrentP3",
    #    $decoded_json->{circuitMaxCurrentP3} );
    #readingsBulkUpdate( $hash, "charger_enableIdleCurrent",
    #    $decoded_json->{enableIdleCurrent} );
    #readingsBulkUpdate(
    #    $hash,
    #    "charger_limitToSinglePhaseCharging",
    #    $decoded_json->{limitToSinglePhaseCharging}
    #);

    #readingsBulkUpdate( $hash, "charger_localNodeType",
    #    $decoded_json->{localNodeType} );

    #readingsBulkUpdate( $hash, "charger_localRadioChannel",
    #    $decoded_json->{localRadioChannel} );
    #readingsBulkUpdate( $hash, "charger_localShortAddress",
    #    $decoded_json->{localShortAddress} );
    #readingsBulkUpdate(
    #    $hash,
    #    "charger_localParentAddrOrNumOfNodes",
    #    $decoded_json->{localParentAddrOrNumOfNodes}
    #);
    #readingsBulkUpdate(
    #    $hash,
    #    "charger_localPreAuthorizeEnabled",
    #    $decoded_json->{localPreAuthorizeEnabled}
    #);
    #readingsBulkUpdate(
    #    $hash,
    #    "charger_allowOfflineTxForUnknownId",
    #    $decoded_json->{allowOfflineTxForUnknownId}
    #);
    #readingsBulkUpdate( $hash, "chargingSchedule",
    #    $decoded_json->{chargingSchedule} );
    readingsBulkUpdate( $hash, "lastResponse",
        'OK - getChargerConfig', 1 );
    readingsEndUpdate( $hash, 1 );
    return;
}

sub Processing_DpointGetCurrentSession {
    my $hash         = shift;
    my $decoded_json = shift;
    my $name = $hash->{NAME};
    my $value;

    readingsBeginUpdate($hash);
    readingsBulkUpdate( $hash, "session_energy",
        sprintf( "%.2f", $decoded_json->{sessionEnergy} ) );
    $value =
      defined $decoded_json->{sessionStart}
      ? _transcodeDate( $decoded_json->{sessionStart} )
      : 'N/A';
    readingsBulkUpdate( $hash, "session_start", $value );
    $value =
      defined $decoded_json->{sessionEnd}
      ? _transcodeDate( $decoded_json->{sessionEnd} )
      : 'N/A';
    readingsBulkUpdate( $hash, "session_end", $value );
    readingsBulkUpdate(
        $hash,
        "session_chargeDurationInSeconds",
        $decoded_json->{chargeDurationInSeconds}
    );
    $value =
      defined $decoded_json->{firstEnergyTransferPeriodStart}
      ? _transcodeDate(
        $decoded_json->{firstEnergyTransferPeriodStart} )
      : 'N/A';
    readingsBulkUpdate( $hash, "session_firstEnergyTransfer", $value );
    $value =
      defined $decoded_json->{lastEnergyTransferPeriodStart}
      ? _transcodeDate( $decoded_json->{lastEnergyTransferPeriodStart} )
      : 'N/A';
    readingsBulkUpdate( $hash, "session_lastEnergyTransfer", $value );
    readingsBulkUpdate( $hash, "session_pricePerKWH",
        $decoded_json->{pricePrKwhIncludingVat} );
    readingsBulkUpdate( $hash, "session_chargingCost",
        sprintf( "%.2f", $decoded_json->{costIncludingVat} ) );
    readingsBulkUpdate( $hash, "session_id",
        $decoded_json->{sessionId} );
    readingsBulkUpdate( $hash, "lastResponse",
        'OK - getCurrentSession', 1 );
    readingsEndUpdate( $hash, 1 );
    return;
}

sub Processing_DpointGetChargerSite {
    my $hash         = shift;
    my $decoded_json = shift;

    my $name = $hash->{NAME};
    readingsBeginUpdate($hash);
    readingsBulkUpdate( $hash, "cost_perKWh",
        $decoded_json->{costPerKWh} );
    readingsBulkUpdate( $hash, "cost_perKwhExcludeVat",
        $decoded_json->{costPerKwhExcludeVat} );
    readingsBulkUpdate( $hash, "cost_vat", $decoded_json->{vat} );
    readingsBulkUpdate( $hash, "cost_currency",
        $decoded_json->{currencyId} );
    readingsBulkUpdate( $hash, "circuit_id",
            $decoded_json->{circuits}->[0]->{id} );

    #readingsBulkUpdate( $hash, "site_ratedCurrent", $decoded_json->{ratedCurrent} );
    #readingsBulkUpdate( $hash, "site_createdOn",    $decoded_json->{createdOn} );
    #readingsBulkUpdate( $hash, "site_updatedOn",    $decoded_json->{updatedOn} );
    readingsBulkUpdate( $hash, "lastResponse",
        'OK - getChargerSite', 1 );
    readingsEndUpdate( $hash, 1 );
    return;
}



sub Processing_DpointGetDynamicCurrent {
    my $hash         = shift;
    my $decoded_json = shift;

    my $name = $hash->{NAME};
    readingsBeginUpdate($hash);

    readingsBulkUpdate( $hash, "dynamicCurrent_phase1",
        $decoded_json->{phase1} );
    readingsBulkUpdate( $hash, "dynamicCurrent_phase2",
        $decoded_json->{phase2} );
    readingsBulkUpdate( $hash, "dynamicCurrent_phase3",
        $decoded_json->{phase3} );

    readingsBulkUpdate( $hash, "lastResponse",
        'OK - getDynamicCurrent', 1 );
    readingsEndUpdate( $hash, 1 );
    return;
}



sub Processing_DpointGetChargers {
    my $hash         = shift;
    my $decoded_json = shift;
    my $name         = $hash->{NAME};
    my $index;

    my $site    = $decoded_json->[0];
    my $circuit = $site->{circuits}->[0];

    #If a fixed charger is selected, find the charger data
    my $fixedChargerId = InternalVal( $name, 'FIXED_CHARGER_ID', undef );
    if (defined $fixedChargerId) {
        my @chargerList = @{$circuit->{chargers}};
        for my $i (0 .. $#chargerList) {
            $index = $i     if $chargerList[$i]->{id} eq $fixedChargerId;
            Log3 $name, 5, "Compared  ". $chargerList[$i]->{id} . " and ". $fixedChargerId;
        }
    } else {
        $index = 0;
        Log3 $name, 5, "No fixed charger ID, using first charger as default."
    }

    my $charger = $circuit->{chargers}->[$index];

    my $chargerId = $charger->{id};

    readingsBeginUpdate($hash);
    readingsBulkUpdate( $hash, "site_id",      $site->{id} );
    readingsBulkUpdate( $hash, "site_key",     $site->{siteKey} );
    readingsBulkUpdate( $hash, "charger_id",   $chargerId );
    readingsBulkUpdate( $hash, "charger_name", $charger->{name} );
    readingsBulkUpdate( $hash, "lastResponse", 'OK - getReaders', 1 );
    readingsEndUpdate( $hash, 1 );

    WriteToCloudAPI( $hash, 'getChargerConfiguration', 'GET' );
    return;
}

sub Processing_DpointGetDailyEnergyConsumption {
    my $hash         = shift;
    my $decoded_json = shift;
    my $name = $hash->{NAME};

    Log3 $name, 5, 'Evaluating GetDailyEnergyConsumption';

    #If less than 7 days of data is available. take only available data
    #otherwise take days
    my $arrayLength = scalar @{$decoded_json} ;
    my $elementCount = min(7,$arrayLength);
    my @a = ( ($elementCount * -1) .. -1 );
    Log3 $name, 5, "Taking historic data of last $elementCount days";

    readingsBeginUpdate($hash);
    for (@a) {
        readingsBulkUpdate(
            $hash,
            "daily_" . ( $_ + 1 ) . "_consumption",
            sprintf( "%.2f", $decoded_json->[$_]->{'consumption'} )
        );
        readingsBulkUpdate(
            $hash,
            "daily_" . ( $_ + 1 ) . "_cost",
            sprintf( "%.2f", $decoded_json->[$_]->{'consumption'} * ReadingsVal($name, "cost_perKWh", 0) )
        );
    }
    readingsEndUpdate( $hash, 1 );
    return;
}

sub Processing_DpointGetChargerSessionsDaily {
    my $hash         = shift;
    my $decoded_json = shift;
    my $name = $hash->{NAME};

    Log3 $name, 5, 'Evaluating getChargerSessionsDaily';


   my $startDate = DateTime->now();
   my $counter = 0;

   readingsBeginUpdate($hash);
   while( $counter <= 7 ) {

     #Search in the returned data if it contains info for the specific day
     my @matches = grep { $_->{'dayOfMonth'} == $startDate->day && $_->{'month'} == $startDate->month && $_->{'year'} == $startDate->year } @{$decoded_json};

      my $energyOffset = ($counter == 0) ?  ReadingsVal( $name, 'session_energy', 0 ) : 0;
      my $costOffset = ($counter == 0) ?  ReadingsVal( $name, 'session_chargingCost', 0 ) : 0;

       readingsBulkUpdate(
           $hash,
           "daily_".($counter*-1)."_energy",
           ((scalar @matches == 1)? @matches[0]->{'totalEnergyUsage'}: 0) + $energyOffset
       );
       readingsBulkUpdate(
           $hash,
           "daily_".($counter*-1)."_cost",
           ((scalar @matches == 1)? @matches[0]->{'totalCost'} : 0) + $costOffset
       );

       $startDate->add(days => -1);
       $counter++;
   }
   readingsEndUpdate( $hash, 1 );

    #If less than 7 days of data is available. take only available data
    #otherwise take days
    my $arrayLength = scalar @{$decoded_json} ;
    my $elementCount = min(7,$arrayLength);
    my @a = ( ($elementCount * -1) .. -1 );
    Log3 $name, 5, "Taking historic data of last $elementCount days";

    readingsBeginUpdate($hash);
    for (@a) {
        Log3 $name, 5, 'laeuft noch: ' . $_;
        readingsBulkUpdate(
            $hash,
            "dailyHistory_" . ( $_ + 1 ) . "_energy",
            sprintf( "%.2f", $decoded_json->[$_]->{'totalEnergyUsage'} )
        );
        readingsBulkUpdate(
            $hash,
            "dailyHistory_" . ( $_ + 1 ) . "_cost",
            sprintf( "%.2f", $decoded_json->[$_]->{'totalCost'} )
        );
        readingsBulkUpdate(
            $hash,
            "dailyHistory_" . ( $_ + 1 ) . "_date",
             sprintf("%04d-%02d-%02d" , $decoded_json->[$_]->{'year'}, $decoded_json->[$_]->{'month'} ,$decoded_json->[$_]->{'dayOfMonth'})
        );
    }
    readingsEndUpdate( $hash, 1 );
    return;
}

sub Processing_DpointGetMonthlyEnergyConsumption {
    my $hash         = shift;
    my $decoded_json = shift;
    my $name = $hash->{NAME};

    Log3 $name, 4, 'Evaluating getMonthlyEnergyConsumption';

    #If less than 6 months of data is available. take only available data
    #otherwise take 6 months
    my $arrayLength = scalar @{$decoded_json} ;
    my $elementCount = min(6,$arrayLength);
    my @a = ( ($elementCount * -1) .. -1 );
    Log3 $name, 5, "Taking historic data of last $elementCount months";


    readingsBeginUpdate($hash);
    for (@a) {
        Log3 $name, 5, 'laeuft noch: ' . $_;
        readingsBulkUpdate(
            $hash,
            "monthly_" . ( $_ + 1 ) . "_consumption",
            sprintf(
                "%.2f", $decoded_json->[$_]->{'consumption'}
            )
        );
        readingsBulkUpdate(
            $hash,
            "monthly_" . ( $_ + 1 ) . "_cost",
            sprintf( "%.2f", $decoded_json->[$_]->{'consumption'} * ReadingsVal($name, "cost_perKWh", 0) )
        );
    }
    readingsEndUpdate( $hash, 1 );
    return;
}

sub _loadToken {
    my $hash          = shift;
    my $name          = $hash->{NAME};
    my $tokenLifeTime = $hash->{TOKEN_LIFETIME};
    $tokenLifeTime = 0 if ( !defined $tokenLifeTime || $tokenLifeTime eq '' );
    my $token;

    $token = $hash->{'.TOKEN'};

    if ( $@ || $tokenLifeTime < gettimeofday() ) {
        Log3 $name, 5,
          "EaseeWallbox $name" . ": "
          . "Error while loading: $@ ,requesting new one"
          if $@;
        Log3 $name, 5,
          "EaseeWallbox $name" . ": " . "Token is expired, requesting new one"
          if $tokenLifeTime < gettimeofday();
        $token = _newTokenRequest($hash);
    }
    else {
        Log3 $name, 5,
            "EaseeWallbox $name" . ": "
          . "Token expires at "
          . localtime($tokenLifeTime);

        # if token is about to expire, refresh him
        if ( ( $tokenLifeTime - 600 ) < gettimeofday() ) {
            Log3 $name, 5,
              "EaseeWallbox $name" . ": "
              . "Token will expire soon, refreshing";
            $token = _tokenRefresh($hash);
        }
    }

    $token = $token ? $token : undef;
    return $token;
}

sub _newTokenRequest {
    my $hash     = shift;
    my $name     = $hash->{NAME};
    my $password = _decrypt( InternalVal( $name, 'Password', undef ) );
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
        timeout => 3,
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
                $hash->{TOKEN_LIFETIME} =
                  gettimeofday() + $decoded_data->{'expiresIn'};
            }
            $hash->{TOKEN_LIFETIME_HR} = localtime( $hash->{TOKEN_LIFETIME} );
            Log3 $name, 5,
                "EaseeWallbox $name" . ": "
              . "Retrived new authentication token successfully. Valid until "
              . localtime( $hash->{TOKEN_LIFETIME} );
            readingsSingleUpdate( $hash, 'state', 'reachable', 1 );
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
        timeout => 3,
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

        # $hash->{STATE} = "error";
        readingsSingleUpdate( $hash, 'state', 'error', 1 );
    }

    elsif ( $returnData ne "" ) {
        Log3 $name, 5, "url " . $param->{url} . " returned: $returnData";
        my $decoded_data = eval { decode_json($returnData); };

        if ($@) {
            Log3 $name, 3,
              "EaseeWallbox $name" . ": "
              . "TokenRefresh: decode_json failed, invalid json. error:$@\n"
              if $@;

            # $hash->{STATE} = "error";
            readingsSingleUpdate( $hash, 'state', 'error', 1 );
        }
        else {
            #write token data in file
            if ( defined($decoded_data) ) {
                $hash->{'.TOKEN'} = $decoded_data;

            }

            # token lifetime management
            $hash->{TOKEN_LIFETIME} =
              gettimeofday() + $decoded_data->{'expires_in'};
            $hash->{TOKEN_LIFETIME_HR} = localtime( $hash->{TOKEN_LIFETIME} );
            Log3 $name, 5,
                "EaseeWallbox $name" . ": "
              . "TokenRefresh: Refreshed authentication token successfully. Valid until "
              . localtime( $hash->{TOKEN_LIFETIME} );

            # $hash->{STATE} = "reachable";
            readingsSingleUpdate( $hash, 'state', 'reachable', 1 );
            return $decoded_data;
        }
    }
    return;
}

sub _encrypt {
    my ($decoded) = @_;
    my $key = getUniqueId();
    my $encoded;

    return $decoded
      if ( $decoded =~ /crypt:/x )
      ; # Regular expression without "/x" flag. See page 236 of PBP (RegularExpressions::RequireExtendedFormatting)

    for my $char ( split //, $decoded ) {
        my $encode = chop($key);
        $encoded .= sprintf( "%.2x", ord($char) ^ ord($encode) );
        $key = $encode . $key;
    }

    return 'crypt:' . $encoded;
}

sub _decrypt {
    my ($encoded) = @_;
    my $key = getUniqueId();
    my $decoded;

    return $encoded
      if ( $encoded !~ /crypt:/x )
      ; # Regular expression without "/x" flag. See page 236 of PBP (RegularExpressions::RequireExtendedFormatting)

    $encoded = $1
      if ( $encoded =~ /crypt:(.*)/x )
      ; # Regular expression without "/x" flag. See page 236 of PBP (RegularExpressions::RequireExtendedFormatting)

    for my $char ( map { pack( 'C', hex($_) ) } ( $encoded =~ /(..)/xg ) )
    { # Regular expression without "/x" flag. See page 236 of PBP (RegularExpressions::RequireExtendedFormatting)
        my $decode = chop($key);
        $decoded .= chr( ord($char) ^ ord($decode) );
        $key = $decode . $key;
    }

    return $decoded;
}


sub _transcodeDate {
    my $datestr = shift;
    Log3 'EaseeWallbox', 5, 'date to parse: ' . $datestr;
    my $strp = DateTime::Format::Strptime->new(
        on_error => 'croak',
        pattern  => '%Y-%m-%dT%H:%M:%S'
    );
    my $dt = $strp->parse_datetime($datestr);
    $dt->set_time_zone('Europe/Berlin');

    return $dt->strftime('%Y-%m-%d %H:%M:%S');
}

sub NumericToBoolean {
    my $number = shift;

    return      if not defined $number;

    my $result;
    eval {$result = $number == 0 ? 'false' : 'true'; };
    return $result  if not $@;
    return $number;
}

1;    # Ein Modul muss immer mit 1; enden

=pod
=item device
=item summary       Modul to communicate with EaseeCloud
=item summary_DE    Modul zur Kommunikation mit der EaseeCloud
=begin html

<a name="EaseeWallbox"></a>
<h3>EaseeWallbox</h3>
<ul>
  <i>EaseeWallbox</i> connects your FHEM instance with the Easee Cloud to interact with your Easee wallbox. All communication takes place via the Easee cloud API and the cloud interacts with the wallbox. If the wallbox is offline none of the functions within this module will work.
</ul>
<br>
<a name="EaseeWallboxdefine"></a>
<b>Define</b>
<ul>
  <code>define &lt;name&gt; EaseeWallbox &lt;username&gt; &lt;password&gt; [&lt;interval&gt;] [&lt;chargerID&gt;]</code><br>
  Interval is the polling interval in seconds (default 60, minimum 5). The optional chargerID selects a specific charger when multiple chargers are registered.
</ul>
<br>
<a name="EaseeWallboxset"></a>
<b>Set</b>
<ul>
  <li>activateTimer - start periodic refresh of readings</li>
  <li>deactivateTimer - stop periodic refresh of readings</li>
  <li>startCharging - allow a charger with authorizationRequired&nbsp;= true to deliver power; otherwise no effect</li>
  <li>stopCharging - stop an authorized charger from delivering power and revoke authorization; no effect if authorizationRequired is false or the charger is not authorized</li>
  <li>pauseCharging - pause the current charging session but keep authorization; limits dynamic charger current to 0 and resets on new car connection</li>
    <li>resumeCharging - resume a paused charging session and restore dynamic charger current limits</li>
    <li>enabled / disabled - enable or disable the charger</li>
  <li>enableSmartButton&nbsp;true|false - enable or disable the smart button</li>
  <li>authorizationRequired&nbsp;true|false - require authorization before charging starts</li>
  <li>cableLock&nbsp;true|false - permanently lock or unlock the charging cable</li>
  <li>enableSmartCharging&nbsp;true|false - switch smart charging on or off</li>
  <li>ledStripBrightness&nbsp;&lt;0-100&gt; - set LED strip brightness</li>
  <li>dynamicCurrent&nbsp;&lt;p1&gt; &lt;p2&gt; &lt;p3&gt; [&lt;ttl&gt;] - set dynamic current for each phase with optional time‑to‑live</li>
  <li>pairRfidTag&nbsp;[&lt;timeout&gt;] - start RFID pairing (default 60&nbsp;s)</li>
  <li>pricePerKWH&nbsp;&lt;price&gt; - set price per kWh (currency EUR, VAT 19%)</li>
  <li>refreshToken - refresh OAuth token</li>
  <li>reboot - reboot the charger</li>
  <li>updateFirmware - trigger firmware update</li>
  <li>overrideChargingSchedule</li>
</ul>
<br>
<a name="EaseeWallboxget"></a>
<b>Get</b>
<ul>
  <li>update - refresh all data immediately</li>
    <li>charger - reload basic charger information</li>
  </ul>
<br>
<a name="EaseeWallboxattr"></a>
<b>Attributes</b>
<ul>
  <li>interval - polling interval in seconds (default 60)</li>
  <li>expertMode&nbsp;yes|no</li>
  <li>SmartCharging&nbsp;true|false - automatically enable smart charging</li>
</ul>
<br>
<a name="EaseeWallboxreadings"></a>
<b>Readings</b>
<ul>
  <li><b>Basic information</b></li>
  <li>charger_id, charger_name, site_id, site_key, circuit_id</li>
  <li><b>Charger configuration</b></li>
  <li>isEnabled, isCablePermanentlyLocked, isAuthorizationRequired, isRemoteStartRequired, isSmartButtonEnabled, isLocalAuthorizationRequired, wiFiSSID, phaseModeId, phaseMode, maxChargerCurrent, ledStripBrightness</li>
  <li><b>Site configuration</b></li>
  <li>cost_perKWh, cost_perKwhExcludeVat, cost_vat, cost_currency</li>
  <li><b>Charger state</b></li>
  <li>operationModeCode, operationMode, online, power, current, dynamicCurrent, kWhInSession, latestPulse, reasonCodeForNoCurrent, reasonForNoCurrent, errorCode, fatalErrorCode, lifetimeEnergy, voltage, wifi_rssi, wifi_apEnabled, cell_rssi</li>
  <li><b>Current session</b></li>
  <li>session_energy, session_start, session_end, session_chargeDurationInSeconds, session_firstEnergyTransfer, session_lastEnergyTransfer, session_pricePerKWH, session_chargingCost, session_id</li>
  <li><b>Dynamic current</b></li>
  <li>dynamicCurrent_phase1, dynamicCurrent_phase2, dynamicCurrent_phase3</li>
  <li><b>Historic consumption</b></li>
  <li>daily_1_consumption .. daily_7_consumption, daily_1_cost .. daily_7_cost</li>
</ul>
<br>
=end html
=cut
