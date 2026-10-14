use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);

BEGIN {
    $INC{'GPUtils.pm'} = 1;
    package GPUtils;
    sub import {
        my ($class, @symbols) = @_;
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::GP_Import"} = \&GP_Import;
        *{"${caller}::GP_Export"} = \&GP_Export;
    }
    sub GP_Import {
        my $caller = caller;
        no strict 'refs';
        for my $symbol (@_) {
            if ($symbol eq 'readingFnAttributes') {
                *{"${caller}::$symbol"} = \$main::readingFnAttributes;
            } elsif ($symbol eq 'defs') {
                *{"${caller}::$symbol"} = \%main::defs;
            } else {
                *{"${caller}::$symbol"} = \&{"main::$symbol"};
            }
        }
    }
    sub GP_Export { }

    $INC{'HttpUtils.pm'} = 1;
    package HttpUtils;

    $INC{'DateTime.pm'} = 1;
    package DateTime;
    $INC{'DateTime/Format/Strptime.pm'} = 1;
    package DateTime::Format::Strptime;
    sub new { bless {}, shift }
}

our (%READINGS, @LOGS, @UPDATES, $NOW, $BLOCKING_RESPONSE, $BLOCKING_ERROR, $LAST_REQUEST, $ASYNC_REQUESTS, $readingFnAttributes, %defs);
$readingFnAttributes = '';
$NOW = 1000;

sub readingFnAttributes { '' }
sub Log3 { push @LOGS, [@_] }
sub readingsBeginUpdate { }
sub readingsEndUpdate { }
sub readingsBulkUpdate {
    my ($hash, $key, $value) = @_;
    $READINGS{$key} = $value;
    push @UPDATES, $key;
}
sub readingsSingleUpdate { readingsBulkUpdate(@_) }
sub readingsDelete { delete $READINGS{$_[1]} }
sub InternalVal { my ($device, $key, $default) = @_; $device = $defs{$device} unless ref($device); return ref($device) eq 'HASH' && exists $device->{$key} ? $device->{$key} : $default }
sub ReadingsVal { return exists $READINGS{$_[1]} ? $READINGS{$_[1]} : $_[2] }
sub RemoveInternalTimer { }
sub InternalTimer { }
sub gettimeofday { $NOW }
sub getUniqueId { 'test' }
sub HttpUtils_NonblockingGet { $LAST_REQUEST = $_[0]; $ASYNC_REQUESTS++ }
sub HttpUtils_BlockingGet { return ($BLOCKING_ERROR // '', $BLOCKING_RESPONSE // '') }

require './98_EaseeWallbox.pm';

my $hash = { NAME => 'wallbox', APIURI => 'https://api.easee.cloud/api/', Username => 'u', Password => 'p', '.TOKEN' => { accessToken => 'a', refreshToken => 'r', tokenType => 'Bearer' }, TOKEN_LIFETIME => 100000 };
$defs{wallbox} = $hash;
$READINGS{charger_id} = 'SERIAL';

FHEM::EaseeWallbox::WriteToCloudAPI($hash, 'getChargerState', 'GET');
is($LAST_REQUEST->{url}, 'https://api.easee.com/state/SERIAL/observations?ids=48,96,109,110,114,119,120,121,124,130,132,250', 'uses official observation endpoint and requested ids');

my $ts1 = '2026-09-11T08:32:52.000Z';
my $ts2 = '2026-09-11T08:34:52.000Z';
my @observations = (
    { id => 109, value => 1, timestamp => $ts1 }, { id => 120, value => 0, timestamp => $ts1 },
    { id => 121, value => 11.38194465637207, timestamp => $ts1 }, { id => 110, value => 0, timestamp => $ts1 },
    { id => 114, value => 0, timestamp => $ts1 }, { id => 48, value => 32, timestamp => $ts1 },
    { id => 96, value => 50, timestamp => $ts1 }, { id => 119, value => 0, timestamp => $ts1 },
    { id => 124, value => 5843.285, timestamp => $ts1 }, { id => 250, value => JSON::PP::true, timestamp => $ts1 },
    { id => 132, value => -47, timestamp => $ts1 }, { id => 130, value => -68, timestamp => $ts1 },
);
FHEM::EaseeWallbox::ResponseHandling({ hash => $hash, dpoint => 'getChargerState', code => 200, url => 'https://api.easee.com/state/SERIAL/observations', method => 'GET' }, '', encode_json({ observations => \@observations }));
is($READINGS{operationModeCode}, 1, 'maps operation mode');
is($READINGS{operationMode}, 'Standby', 'maps operation mode label');
is($READINGS{power}, '0.00', 'preserves zero power');
is($READINGS{current}, 0, 'preserves zero current');
is($READINGS{online}, 'true', 'maps boolean online');
is($READINGS{reasonCodeForNoCurrent}, 50, 'maps reason code zero safely');
is($READINGS{reasonForNoCurrent}, 'SecondaryUnitNotRequestingCurrent', 'maps reason label');
is($READINGS{power_sourceTimestamp}, $ts1, 'keeps exact UTC source timestamp');
is($READINGS{operationMode_sourceTimestamp}, $ts1, 'keeps timestamp for every mapped reading');
is($READINGS{chargerStateStatus}, 'ok', 'marks valid observation response successful');

@UPDATES = ();
FHEM::EaseeWallbox::ResponseHandling({ hash => $hash, dpoint => 'getChargerState', code => 200, url => 'https://api.easee.com/state/SERIAL/observations', method => 'GET' }, '', encode_json({ observations => [ { id => 120, value => 9, timestamp => $ts1 } ] }));
is($READINGS{power}, '0.00', 'does not rewrite an observation at the same timestamp');
ok(!grep(/^power(?:_sourceTimestamp)?$/, @UPDATES), 'repeated observation does not write readings or emit events');
FHEM::EaseeWallbox::ResponseHandling({ hash => $hash, dpoint => 'getChargerState', code => 200, url => 'https://api.easee.com/state/SERIAL/observations', method => 'GET' }, '', encode_json({ observations => [ { id => 120, value => 8, timestamp => '2026-09-10T08:32:52.000Z' } ] }));
is($READINGS{power}, '0.00', 'does not let an older observation overwrite newer value');
FHEM::EaseeWallbox::ResponseHandling({ hash => $hash, dpoint => 'getChargerState', code => 200, url => 'https://api.easee.com/state/SERIAL/observations', method => 'GET' }, '', encode_json({ observations => [ { id => 120, value => 1, timestamp => $ts2 } ] }));
is($READINGS{power}, '1.00', 'accepts a genuinely newer observation');
FHEM::EaseeWallbox::ResponseHandling({ hash => $hash, dpoint => 'getChargerState', code => 200, url => 'https://api.easee.com/state/SERIAL/observations', method => 'GET' }, '', encode_json({ observations => [ { id => 250, value => JSON::PP::false, timestamp => '2026-09-11T08:35:52.000Z' } ] }));
is($READINGS{online}, 'false', 'preserves false boolean observations');
FHEM::EaseeWallbox::ResponseHandling({ hash => $hash, dpoint => 'getChargerState', code => 200, url => 'https://api.easee.com/state/SERIAL/observations', method => 'GET' }, '', encode_json({ observations => [ { id => 109, value => 7, timestamp => '2026-09-11T08:36:52.000Z' }, { id => 96, value => 999, timestamp => '2026-09-11T08:36:52.000Z' } ] }));
is($READINGS{operationMode}, 'Unknown(7)', 'unknown newer operation mode does not leave stale label');
is($READINGS{reasonForNoCurrent}, 'Unknown(999)', 'unknown newer reason does not leave stale label');

FHEM::EaseeWallbox::ResponseHandling({ hash => $hash, dpoint => 'getChargerState', code => 403, url => 'https://api.easee.com/state/SERIAL/observations', method => 'GET' }, '', 'Forbidden');
is($READINGS{chargerStateStatus}, 'error', 'keeps state API failure distinct');
FHEM::EaseeWallbox::ResponseHandling({ hash => $hash, dpoint => 'getChargerState', code => 0, url => 'https://api.easee.com/state/SERIAL/observations', method => 'GET' }, 'timeout', '');
like($READINGS{chargerStateError}, qr/Network error/, 'network failure is recorded as state error');
FHEM::EaseeWallbox::ResponseHandling({ hash => $hash, dpoint => 'getChargerSite', code => 200, url => 'https://api.easee.cloud/api/chargers/SERIAL/site', method => 'GET' }, '', encode_json({ id => 1 }));
is($READINGS{chargerStateStatus}, 'error', 'unrelated successful API response does not clear state failure');
FHEM::EaseeWallbox::ResponseHandling({ hash => $hash, dpoint => 'getChargerState', code => 200, url => 'https://api.easee.com/state/SERIAL/observations', method => 'GET' }, '', encode_json({ observations => [] }));
is($READINGS{chargerStateStatus}, 'error', 'empty observation list is unhealthy');
FHEM::EaseeWallbox::ResponseHandling({ hash => $hash, dpoint => 'getChargerState', code => 200, url => 'https://api.easee.com/state/SERIAL/observations', method => 'GET' }, '', encode_json({ observations => [ { id => 120, value => 7, timestamp => '2026-99-99T08:32:52.000Z' } ] }));
is($READINGS{chargerStateStatus}, 'error', 'invalid calendar timestamps are rejected');
for my $bad_value (undef, [], {}, 'not-a-number') {
    FHEM::EaseeWallbox::ResponseHandling(
        { hash => $hash, dpoint => 'getChargerState', code => 200, url => 'https://api.easee.com/state/SERIAL/observations', method => 'GET' },
        '', encode_json({ observations => [ { id => 120, value => $bad_value, timestamp => '2026-09-11T08:40:00.000Z' } ] })
    );
    is($READINGS{chargerStateStatus}, 'error', 'null, reference and nonnumeric values are rejected');
    is($READINGS{power_sourceTimestamp}, $ts2, 'invalid value does not advance source timestamp');
}
FHEM::EaseeWallbox::ResponseHandling({ hash => $hash, dpoint => 'getChargerState', code => 200, url => 'https://api.easee.com/state/SERIAL/observations', method => 'GET' }, '', '{');
like($READINGS{chargerStateError}, qr/Invalid|valid/, 'malformed payload records state error');

$BLOCKING_RESPONSE = encode_json({ accessToken => 'new-a', refreshToken => 'new-r', tokenType => 'Bearer', expiresIn => 3600 });
$BLOCKING_ERROR = '';
FHEM::EaseeWallbox::_tokenRefresh($hash);
is($hash->{'.TOKEN'}{accessToken}, 'new-a', 'refresh accepts camelCase expiresIn and valid token pair');
is($hash->{TOKEN_LIFETIME}, 4600, 'refresh stores positive expiry');
$BLOCKING_RESPONSE = encode_json({ accessToken => 'bad', refreshToken => '', tokenType => 'Bearer', expiresIn => 3600 });
FHEM::EaseeWallbox::_tokenRefresh($hash);
is($hash->{'.TOKEN'}{accessToken}, 'new-a', 'invalid token response does not replace valid credentials');
$BLOCKING_RESPONSE = '{';
FHEM::EaseeWallbox::_tokenRefresh($hash);
is($hash->{'.TOKEN'}{accessToken}, 'new-a', 'decode failure does not leak or replace credentials');
ok(!grep(/new-a|new-r|bad|accessToken|refreshToken/, map { $_->[2] // '' } @LOGS), 'verbose logs omit token material');
$BLOCKING_RESPONSE = encode_json({ accessToken => 'initial-a', refreshToken => 'initial-r', tokenType => 'Bearer', expiresIn => 1800 });
FHEM::EaseeWallbox::_newTokenRequest($hash);
is($hash->{'.TOKEN'}{accessToken}, 'initial-a', 'initial token request accepts camelCase expiresIn');
is($hash->{TOKEN_LIFETIME}, 2800, 'initial token request stores positive expiry');
$BLOCKING_RESPONSE = encode_json({ accessToken => 'invalid-a', refreshToken => 'initial-r', tokenType => 'Bearer', expiresIn => 0 });
FHEM::EaseeWallbox::_newTokenRequest($hash);
is($hash->{'.TOKEN'}{accessToken}, 'initial-a', 'invalid initial token response preserves last valid pair');

$BLOCKING_ERROR = 'transport accessToken=synthetic-access refreshToken=synthetic-refresh';
$BLOCKING_RESPONSE = '';
$hash->{TOKEN_LIFETIME} = $NOW + 300;
my $usable_token = FHEM::EaseeWallbox::_loadToken($hash);
is($usable_token->{accessToken}, 'initial-a', 'failed refresh falls back to still-valid existing token');
$BLOCKING_ERROR = '';
$BLOCKING_RESPONSE = 'malformed synthetic-refresh refreshToken=synthetic-refresh';
FHEM::EaseeWallbox::_tokenRefresh($hash);
$BLOCKING_RESPONSE = 'malformed synthetic-access accessToken=synthetic-access';
$BLOCKING_ERROR = '';
FHEM::EaseeWallbox::_newTokenRequest($hash);
$BLOCKING_ERROR = 'transport accessToken=synthetic-access refreshToken=synthetic-refresh';
FHEM::EaseeWallbox::_newTokenRequest($hash);
ok(!grep(/synthetic-access|synthetic-refresh|initial-a|initial-r/, map { $_->[2] // '' } @LOGS), 'auth transport and malformed response content never appears in log text');

ok(!FHEM::EaseeWallbox::_validTokenPair({ accessToken => [], refreshToken => 'r', tokenType => 'Bearer' }), 'token fields must be scalar');
ok(!FHEM::EaseeWallbox::_validTokenPair({ accessToken => ' ', refreshToken => 'r', tokenType => 'Bearer' }), 'token credentials must not be whitespace only');
ok(!FHEM::EaseeWallbox::_tokenLifetime({ expiresIn => [] }), 'token lifetime must be scalar');

my $no_token_hash = { NAME => 'noToken', APIURI => 'https://api.easee.cloud/api/', Username => 'u', Password => 'p', TOKEN_LIFETIME => 0 };
$defs{noToken} = $no_token_hash;
$BLOCKING_ERROR = 'login failure';
$BLOCKING_RESPONSE = '';
$READINGS{chargerStateStatus} = 'ok';
my $before_requests = $ASYNC_REQUESTS;
my $result = FHEM::EaseeWallbox::WriteToCloudAPI($no_token_hash, 'getChargerState', 'GET');
like($result, qr/No valid Easee OAuth token/, 'missing token returns a clear local error');
is($ASYNC_REQUESTS, $before_requests, 'request is not sent with an empty Bearer token');
is($READINGS{chargerStateStatus}, 'error', 'authentication failure marks state poll unhealthy');
like($READINGS{chargerStateError}, qr/Authentication failed/, 'state poll records authentication failure');

done_testing();
