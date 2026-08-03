#!/usr/bin/env bash
#
# setup-google-device-access.sh — automate Part 1 of this guide: the Google Cloud
# and Device Access setup that produces the four credentials the Nest plugin needs
# (clientId, clientSecret, projectId, refreshToken) plus a Pub/Sub subscription for
# motion and doorbell events.
#
# ADAPTED, WITH THANKS, FROM WeekendSuperhero's setup-nest-sdm.sh
#   https://github.com/potmat/homebridge-google-nest-sdm/pull/209
# That PR (ISC, compatible with this repo's MIT) worked out that the Cloud half of
# this setup is scriptable at all. This guide previously asserted the opposite. The
# gcloud sequence below is theirs; the changes are noted under "Differences" below.
#
# WHAT IS AND IS NOT AUTOMATED
#   Automated : GCP project, SDM + Pub/Sub API enablement, topic, sdm-publisher IAM
#               binding, pull subscription, the OAuth token exchange, and writing a
#               ready-to-paste Homebridge config block.
#   Manual    : the $5 Device Access registration, the OAuth consent screen, creating
#               the OAuth client, linking the topic in the Device Access Console, and
#               approving the authorization URL. All five need a browser and a human;
#               the script walks you to the exact page and waits.
#
# DIFFERENCES FROM PR #209
#   1. Dry run by DEFAULT. Nothing is created until you pass --apply. Every gcloud
#      command is printed first so you can read what it will do to your account.
#   2. The token-exchange failure path no longer prints the raw response. #209 does
#      `echo "Response: $TOKEN_RESPONSE"` when refresh_token is missing -- which is
#      exactly the case where Google returned a valid ACCESS token and no refresh
#      token (re-authorizing a client that already has a grant, without
#      prompt=consent). So the likeliest failure prints a live credential to a
#      terminal the user is about to paste into a bug report. Reported on #209.
#   3. Credentials are written 0600 via a temp file, never 0644-then-chmod.
#   4. Idempotent: existing project/topic/subscription are detected and reused
#      rather than "create and ignore the error", so a re-run is quiet and honest.
#
# TESTING STATUS -- READ THIS
#   The dry-run path, argument handling, prerequisite detection and the token-parsing
#   logic are tested. THE LIVE GCP CALLS ARE NOT: they need a real Google account and
#   a $5 registration, so they have never been executed by the author of this file.
#   The sequence is the one from #209 and matches this guide's manual Part 1, which
#   is known to work. Run with --dry-run first and read it.
#
# Usage:
#   ./setup-google-device-access.sh [--apply] [--project-id ID] [--out FILE] [--help]
set -uo pipefail

APPLY=0
PROJECT_ID=""
OUT="nest-credentials.json"
TOPIC_NAME="${TOPIC_NAME:-nest-events}"
SUBSCRIPTION_NAME="${SUBSCRIPTION_NAME:-nest-events-sub}"

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)      APPLY=1; shift ;;
    --dry-run)    APPLY=0; shift ;;
    --project-id) PROJECT_ID="$2"; shift 2 ;;
    --out)        OUT="$2"; shift 2 ;;
    -h|--help)    sed -n '2,46p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
[ -t 1 ] || { B=""; R=""; G=""; Y=""; D=""; N=""; }

step()   { printf "  %s->%s %s\n" "$G" "$N" "$1"; }
warn()   { printf "  %s!!%s %s\n" "$Y" "$N" "$1"; }
fail()   { printf "  %sxx%s %s\n" "$R" "$N" "$1" >&2; exit 1; }
header() { printf "\n%s%s%s\n" "$B" "$1" "$N"; }
manual() {
  printf "\n%s[MANUAL STEP -- needs a browser]%s %s\n" "$Y" "$N" "$1"
}
pause()  { printf "\n%sPress Enter when done...%s " "$D" "$N"; read -r _ </dev/tty; }

# Every mutating call goes through this, so --dry-run is total rather than
# best-effort. A script that half-runs against someone's cloud account is worse
# than one that does nothing.
run() {
  if [ "$APPLY" = "1" ]; then
    "$@"
  else
    printf "  %s[dry-run]%s %s\n" "$D" "$N" "$*"
  fi
}

# This script is inherently interactive: five steps need a human in a browser, and
# every value it cannot derive is read from /dev/tty (deliberately, so the prompts
# still work when stdout is piped to a log).
#
# Without a controlling terminal those reads FAIL -- and a failed `read` is not
# fatal, so the script would walk straight through every manual step collecting
# empty strings and carry on as though the user had answered. Observed exactly that
# on 2026-08-03: a non-interactive dry run went from "Press Enter when done..." to
# Step 4 without pausing, and would have reached the token exchange with an empty
# client ID. Refuse up front rather than half-run. (--help is handled above and
# still works headless.)
# Brace group, not a bare redirect: the "Device not configured" error comes from the
# shell performing the redirection, before the command runs, so `: >/dev/tty 2>/dev/null`
# still leaks it to the terminal ahead of the clean message below.
if ! { : >/dev/tty; } 2>/dev/null; then
  echo "ERROR: no controlling terminal." >&2
  echo "This script is interactive -- the \$5 registration, the OAuth consent screen," >&2
  echo "the OAuth client, linking the Pub/Sub topic and approving the authorization" >&2
  echo "URL all need a browser and a human. Run it from a terminal." >&2
  exit 1
fi

# ---------------------------------------------------------------- prerequisites
header "Step 0 — prerequisites"
for b in gcloud jq curl; do
  command -v "$b" >/dev/null 2>&1 || fail "$b is required but not installed. gcloud: https://cloud.google.com/sdk/docs/install"
  step "$b found"
done

ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
if [ -z "$ACCOUNT" ]; then
  warn "not logged in to gcloud"
  run gcloud auth login
  ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
fi
step "account: ${ACCOUNT:-<none, dry run>}"

# This one is not a nicety. Workspace accounts CANNOT register for Device Access,
# and a project, once linked to an account, cannot be moved to another.
case "$ACCOUNT" in
  *@gmail.com|"") : ;;
  *) warn "'$ACCOUNT' is not an @gmail.com account. Google Workspace accounts cannot"
     warn "register for Device Access, and a project cannot be moved later. Switch"
     warn "accounts now if this is not deliberate." ;;
esac

if [ "$APPLY" != "1" ]; then
  printf "\n%sDRY RUN — nothing will be created. Re-run with --apply to execute.%s\n" "$Y" "$N"
fi

# ------------------------------------------------------------------ GCP project
header "Step 1 — Google Cloud project"
if [ -z "$PROJECT_ID" ]; then
  printf "  GCP project ID to create or reuse [nest-homebridge]: "
  read -r PROJECT_ID </dev/tty
  PROJECT_ID="${PROJECT_ID:-nest-homebridge}"
fi
if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
  step "project '$PROJECT_ID' already exists — reusing it"
else
  step "creating project '$PROJECT_ID'"
  run gcloud projects create "$PROJECT_ID" --name="$PROJECT_ID"
  # Verify instead of assuming. Nothing here uses `set -e`, so a failed create would
  # otherwise sail on and every later step would run against a project that does not
  # exist -- reporting progress the whole way. Project IDs are unique across ALL of
  # Google Cloud, so the common failure is a name a stranger already took, and
  # `projects describe` cannot distinguish "taken by someone else" from "free":
  # both answer "does not have permission ... (or it may not exist)".
  if [ "$APPLY" = "1" ] && ! gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
    fail "could not create project '$PROJECT_ID'. Project IDs are globally unique, so this one may be taken by another Google Cloud user, or your account may be at its project quota. Pick another and re-run with --project-id NEW_NAME."
  fi
fi
run gcloud config set project "$PROJECT_ID"

header "Step 2 — enable the APIs"
# Matched against the DEFAULT table output (first column is the service name)
# rather than a --format projection. `--format='value(config.name)'` looked right,
# but gcloud validates format strings only after authenticating, so an unauthenticated
# check cannot tell a good projection from a typo -- a deliberately bogus field
# errored identically. An unverifiable projection that silently yields nothing would
# make this branch claim "enabling" forever and never report "already enabled".
# awk with an exact field match avoids both the guess and grep's regex dots.
for api in smartdevicemanagement.googleapis.com pubsub.googleapis.com; do
  if gcloud services list --enabled --project="$PROJECT_ID" 2>/dev/null \
       | awk -v a="$api" 'NR>1 && $1==a {found=1} END{exit !found}'; then
    step "$api already enabled"
  else
    step "enabling $api"
    run gcloud services enable "$api" --project="$PROJECT_ID"
    # Same reasoning as the project check: verify, because everything downstream
    # (topic, IAM binding, subscription) depends on these and would fail one by one
    # with less obvious errors. Enabling an API on a brand-new project is the step
    # most likely to demand a billing account be linked -- which is free to attach
    # and is not the $5 Device Access fee.
    if [ "$APPLY" = "1" ] && ! gcloud services list --enabled --project="$PROJECT_ID" 2>/dev/null \
         | awk -v a="$api" 'NR>1 && $1==a {f=1} END{exit !f}'; then
      fail "enabled $api but it is still not listed. Usually this means the project needs a billing account linked: https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID (free to attach; separate from the \$5 Device Access fee). Link one and re-run."
    fi
  fi
done

# ------------------------------------------------------------------ OAuth client
header "Step 3 — OAuth consent screen"
manual "Configure the consent screen. There is no gcloud equivalent for this."
cat <<EOF
    1. https://console.cloud.google.com/apis/credentials/consent?project=$PROJECT_ID
    2. User type: External  ->  Create
    3. App name: anything.  Support + developer email: $ACCOUNT
    4. Save and continue through each step
    5. Under Audience -> Test users, ADD $ACCOUNT   <- skipping this is the
       single most common cause of 'access_denied' later
EOF
pause

header "Step 4 — OAuth client credentials"
manual "Create the OAuth client and copy both values."
cat <<EOF
    1. https://console.cloud.google.com/apis/credentials?project=$PROJECT_ID
    2. + CREATE CREDENTIALS -> OAuth client ID
    3. Application type: Web application
    4. Authorized redirect URIs -> ADD URI -> https://www.google.com
    5. Create, then copy the Client ID and Client Secret
EOF
pause
printf "  OAuth Client ID: "; read -r CLIENT_ID </dev/tty
printf "  OAuth Client Secret: "; read -rs CLIENT_SECRET </dev/tty; echo
[ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] || fail "both client ID and secret are required"
step "OAuth client captured"

# --------------------------------------------------------------- Device Access
header "Step 5 — Device Access registration (\$5, one time)"
manual "This cannot be automated: it takes a payment."
cat <<EOF
    1. https://console.nest.google.com/device-access
    2. Accept the terms, pay the one-time \$5 fee
    3. Create project -> paste the OAuth Client ID from Step 4
    4. Enable events: YES
    5. Copy the Device Access PROJECT ID -- a UUID like
       32c4c2bc-fe0d-461b-b51c-f3885afff2f0
EOF
printf "\n  %sNote: this UUID is NOT your GCP project ID ('%s'). Mixing the two up%s\n" "$Y" "$PROJECT_ID" "$N"
printf "  %sgives a 404 that the plugin reports only as 'initialization failed'.%s\n" "$Y" "$N"
pause
printf "  Device Access project ID (UUID): "; read -r SDM_PROJECT_ID </dev/tty
[ -n "$SDM_PROJECT_ID" ] || fail "Device Access project ID is required"
step "Device Access project: $SDM_PROJECT_ID"

# -------------------------------------------------------------------- Pub/Sub
# Projects created after January 2025 must self-host their topic; Google stopped
# providing hosted ones (release notes 2025-01-23). Events only -- streaming works
# without any of this.
header "Step 6 — Pub/Sub topic and subscription"
if gcloud pubsub topics describe "$TOPIC_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
  step "topic '$TOPIC_NAME' already exists"
else
  step "creating topic '$TOPIC_NAME'"
  run gcloud pubsub topics create "$TOPIC_NAME" --project="$PROJECT_ID"
fi

step "granting sdm-publisher@googlegroups.com publish rights"
run gcloud pubsub topics add-iam-policy-binding "$TOPIC_NAME" \
    --project="$PROJECT_ID" \
    --member="group:sdm-publisher@googlegroups.com" \
    --role="roles/pubsub.publisher"

if gcloud pubsub subscriptions describe "$SUBSCRIPTION_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
  step "subscription '$SUBSCRIPTION_NAME' already exists"
else
  step "creating pull subscription '$SUBSCRIPTION_NAME'"
  run gcloud pubsub subscriptions create "$SUBSCRIPTION_NAME" \
      --project="$PROJECT_ID" --topic="$TOPIC_NAME" \
      --ack-deadline=20 --message-retention-duration=1d
fi

header "Step 7 — link the topic to Device Access"
manual "Google will not publish anything until the topic is registered there."
cat <<EOF
    1. https://console.nest.google.com/device-access
    2. Open your project -> Pub/Sub topic
    3. Set it to: projects/$PROJECT_ID/topics/$TOPIC_NAME
EOF
pause

# --------------------------------------------------------------------- tokens
header "Step 8 — authorize and exchange for a refresh token"
# BOTH scopes. sdm.service alone authenticates fine and then silently delivers no
# events, which is a miserable thing to debug.
SCOPES="https://www.googleapis.com/auth/sdm.service+https://www.googleapis.com/auth/pubsub"
AUTH_URL="https://nestservices.google.com/partnerconnections/${SDM_PROJECT_ID}/auth?redirect_uri=https://www.google.com&access_type=offline&prompt=consent&client_id=${CLIENT_ID}&response_type=code&scope=${SCOPES}"
manual "Open this URL, approve, then copy the 'code' parameter out of the address bar."
printf "\n%s\n\n" "$AUTH_URL"
echo "    You will land on https://www.google.com/?code=XXXX&scope=... — the code is"
echo "    everything between 'code=' and the next '&', URL-decoded (%2F is '/')."
printf "\n  Authorization code: "; read -r AUTH_CODE </dev/tty
[ -n "$AUTH_CODE" ] || fail "authorization code is required"

if [ "$APPLY" != "1" ]; then
  printf "\n  %s[dry-run]%s would POST to oauth2.googleapis.com/token and write %s\n" "$D" "$N" "$OUT"
  printf "  %sDry run complete. Re-run with --apply to execute.%s\n" "$Y" "$N"
  exit 0
fi

TOKEN_RESPONSE="$(curl -s -X POST https://www.googleapis.com/oauth2/v4/token \
  -d "client_id=${CLIENT_ID}" -d "client_secret=${CLIENT_SECRET}" \
  -d "code=${AUTH_CODE}" -d "grant_type=authorization_code" \
  -d "redirect_uri=https://www.google.com")"

REFRESH_TOKEN="$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.refresh_token // empty')"
if [ -z "$REFRESH_TOKEN" ]; then
  # Deliberately NOT printing $TOKEN_RESPONSE: when refresh_token is absent the
  # response usually still contains a live access_token, and this is the branch a
  # user is most likely to paste into an issue. Only the error fields go out.
  ERR="$(printf '%s' "$TOKEN_RESPONSE" | jq -r '[.error, .error_description] | map(select(.)) | join(": ") // empty')"
  warn "no refresh token in the response${ERR:+ — $ERR}"
  warn "The usual cause is re-authorizing a client that already has a grant."
  warn "Revoke it at https://myaccount.google.com/permissions and run Step 8 again."
  fail "could not obtain a refresh token"
fi
step "refresh token obtained (${REFRESH_TOKEN:0:12}...)"

# 0600 from creation. The output holds a refresh token, which is a long-lived
# credential for your cameras.
umask 077
TMP="$(mktemp "${OUT}.XXXXXX")"
jq -n --arg ci "$CLIENT_ID" --arg cs "$CLIENT_SECRET" --arg pid "$SDM_PROJECT_ID" \
      --arg rt "$REFRESH_TOKEN" --arg sub "projects/$PROJECT_ID/subscriptions/$SUBSCRIPTION_NAME" \
  '{platform:"google-nest-sdm", clientId:$ci, clientSecret:$cs, projectId:$pid,
    refreshToken:$rt, subscriptionId:$sub}' > "$TMP"
mv -f "$TMP" "$OUT"
chmod 600 "$OUT"

header "Done"
step "credentials written to $OUT (mode 0600)"
cat <<EOF

  Add the contents of $OUT to the "platforms" array in your Homebridge config.json,
  restart Homebridge, and confirm your cameras appear. Then continue with Part 3 of
  the guide, or run ./install.sh for the go2rtc + snapshot layer.

  $OUT contains a refresh token. Do not commit it and do not paste it into issues.
EOF
