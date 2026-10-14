# Easee module requirements

## Phase

Production integration: this module is installed in a live FHEM setup. Changes to the Easee API contract require targeted regression coverage before release.

## Charger state and authentication

- Read charger state through `GET https://api.easee.com/state/{serial}/observations?ids=...`; leave other GET and setter URLs unchanged.
- Map only confirmed observations and preserve source values with their UTC timestamps. Do not let equal or older source timestamps rewrite readings or emit freshness events.
- Keep state-poll health separate from other API response health. Missing, invalid, empty, HTTP-error and network-error responses are failures.
- Preserve compatibility readings that have no verified observation source, without inventing replacement values.
- Accept OAuth expiry as Easee's `expiresIn`; save only a valid nonempty access/refresh token pair and positive lifetime. Failed refreshes must preserve the last valid token.
- Verbose logging must not expose credentials, access/refresh tokens, response bodies from token endpoints, or decoder errors containing those bodies.

## Validation and known coverage limits

`prove -v t/state.t` exercises the endpoint URL, confirmed mapping including false/zero values, timestamp ordering/repeats, state-specific errors, unrelated API success, and token refresh validation using local FHEM/HTTP stubs. It does not exercise a live FHEM runtime, OAuth service, or charger. Live API verification and independent review are release checks handled separately.
