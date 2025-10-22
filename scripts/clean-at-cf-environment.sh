#!/usr/bin/env bash
#set -euo pipefail # exit on errors

# Exit immediately if a pipeline returns a non-zero status.
#set -o errexit

# If set, any trap on ERR is inherited by shell functions, command substitutions, and commands executed in a subshell environment. The ERR trap is normally not inherited in such cases.
#set -o errtrace

# See https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
# -u The shell shall write a message to standard error when it tries to expand a variable that  is  not set and immediately exit.
# pipefail
#    If set, the return value of a pipeline is the value of the last (rightmost) command to exit with a non-zero status, or zero if all commands in the pipeline exit successfully. This option is disabled by default.
set -u uo pipefail

set -x # debug traces
declare -i errcount=0
declare -i errcode=0

validate_args() {
  echo "For interactive usage, consider switching cf target or sourcing ~/.osb-cmdb.env on desktops"
  readonly API_HOST="${API_HOST:?must be set}"
  readonly API_PORT="${API_PORT:?must be set}"
  readonly USERNAME="${USERNAME:?must be set}"
  readonly PASSWORD="${PASSWORD:?must be set}" # credential_leak_validated
  readonly DEFAULT_ORG="${DEFAULT_ORG:?must be set}"
  readonly DEFAULT_SPACE="${DEFAULT_SPACE:?must be set}"
  readonly SKIP_SSL_VALIDATION="${SKIP_SSL_VALIDATION:?must be set}"
}

login () {
  cf login --skip-ssl-validation  -a "${API_HOST}" -o "$DEFAULT_ORG" -s "$DEFAULT_SPACE" -u "$USERNAME" -p "$PASSWORD"
}

# $1 service name, e.g. bsn-create-async-instance-with-async-service-keys
function purgeServiceRexposedByPlatformOsbCmdbInstances() {
    NON_AT_OSB_CMDB_BROKERS_LEAKING_AT_SERVICES=$(cf service-access -e $1 | grep "broker: " | awk '{ print $2 }' )
    echo "Purging leak AT service $1 from non-at brokers: ${NON_AT_OSB_CMDB_BROKERS_LEAKING_AT_SERVICES}"
    for b in ${NON_AT_OSB_CMDB_BROKERS_LEAKING_AT_SERVICES}; do
      CF_PURGE_OUTPUT=$(cf purge-service-offering -f -b $b $1)
      if [[ "$CF_PURGE_OUTPUT" =~ "FAILED" ]]; then
        echo "Failed: $CF_PURGE_OUTPUT"
        exit 1
      fi
    done
}

cleanUp() {
  AT_BROKERS=$(cf service-brokers | grep test-broker | awk '{print $1}')
  echo "Cleaning up app broker left overs: [${AT_BROKERS}]"
  for b in ${AT_BROKERS}; do
    SERVICE_DEFINITIONS=$(cf service-access -b $b | tail -n +4 | awk '{print $1}' | uniq )
        echo "Purging services [${SERVICE_DEFINITIONS}] for broker $b"
        for s in ${SERVICE_DEFINITIONS}; do
          CF_PURGE_OUTPUT=$(cf purge-service-offering -f -b $b $s)
          # Can't rely on cf purge-service-offering exit status
          if [[ "$CF_PURGE_OUTPUT" =~ "FAILED" ]]; then
              echo "Failed to purge service offering $s from broker $b due to CLI bug https://github.com/cloudfoundry/cli/issues/1859 Attempting workaround"
              SERVICES_OFFERING_SEARCH_ENDPOINT=$(CF_TRACE=true cf purge-service-offering -f -b $b $s | grep  'GET /v2/services?q=' | awk '{print $2}')
              FIRST_SERVICE_OFFERING_GUID=$(cf curl $SERVICES_OFFERING_SEARCH_ENDPOINT | jq -r .resources[0].metadata.guid)
              FIRST_SERVICE_OFFERING_LABEL=$(cf curl "/v2/services/$FIRST_SERVICE_OFFERING_GUID" | jq .entity.label)
              echo "manually purging service offering guid $FIRST_SERVICE_OFFERING_GUID whose label is $FIRST_SERVICE_OFFERING_LABEL"
              DELETE_OUTPUT=$(cf curl -X DELETE "/v2/services/$FIRST_SERVICE_OFFERING_GUID?purge=true")
              #Can't test $? as cf curl always return 0. See https://github.com/cloudfoundry/cli/issues/1970
              if [[ "$DELETE_OUTPUT" =~ error_code ]]; then
                echo "Workaround for purge failed: $DELETE_OUTPUT"
                exit 1
              fi
          fi
          purgeServiceRexposedByPlatformOsbCmdbInstances $s
        done
        cf delete-service-broker -f $b
  done
  # $ cf apps
  #Getting apps in org osb-cmdb-services-acceptance-tests / space development as XX...
  #
  #name                                    requested state   processes   routes
  #test-broker-app-async-update-instance   started           web:1/1     test-broker-app-async-update-instance.my-domain.org
  APPS=$(cf a | tail -n +4 | awk '{print $1}')
  echo "Deleting apps [$APPS]"
  for a in ${APPS}; do
    cf d -f $a
  done
  # $ cf s
  #Getting services in org osb-cmdb-services-acceptance-tests / space development as XX...
  #
  #name      service   plan   bound apps   last operation     broker    upgrade available
  #gberche   p-mysql   10mb                create succeeded   p-mysql
  SERVICE_INSTANCES=$( cf s | tail -n +4 | awk '{print $1}')
  echo "Deleting services [$SERVICE_INSTANCES]"
  for s in ${SERVICE_INSTANCES} ; do
    cf ds -f $s
  done;
  BACKING_SPACES=$(cf spaces | grep "bsn-" | awk '{print $1}')
  echo "Deleting backing service spaces  [$BACKING_SPACES]"
  for s in ${BACKING_SPACES} ; do
    cf delete-space -f $s
  done;

}

assert_no_more_leaks() {
  echo "You may check there is no remaining left over"
  cf s
  cf a
  #$ cf s
  #Getting services in org osb-cmdb-services-acceptance-tests / space development as XX...
  #
  #No services found
  #$ cf a
  #Getting apps in org osb-cmdb-services-acceptance-tests / space development as XX...
  #
  #No apps found
  cf s > services.txt
  cf a > apps.txt
  if [[ ! $(cat services.txt) =~ "No services found" ]]; then
    echo "leaking services:"
    cat services.txt
    exit 1
  fi
  if [[ ! $(cat apps.txt) =~ "No apps found" ]]; then
    echo "leaking apps:"
    cat apps.txt
    exit 1
  fi
  echo "Making sure that there is no brokers left over"
  cf service-brokers > brokers.txt

  grep test-broker- brokers.txt
  if [[ $? -ne 1 ]]; then
      echo "Unexpected uncleaned up broker: the list should not contain any broker whose name contains [test-broker-] "
      cat brokers.txt
      exit 1
  fi

  echo "Making sure that there is no service definition left over in ocmb brokered services"

  OSB_CMDB_BROKERS=$(cat brokers.txt | grep cmdb | awk '{print $1}')
  for b in $OSB_CMDB_BROKERS; do
    cf service-access -b $b > service-access.txt
    for p in cmdb-dont-use-scab-backing-service bsn app-service backing-service; do
      grep $p service-access.txt
      if [[ $? -ne 1 ]]; then
          echo "Unexpected uncleaned up service definition [$p] in broker [$b] with access"
          cat service-access.txt
          exit 1
      fi
    done;
  done;
}

main() {
  # Allow interactive usage of the script: if already logged in then does not require args and login
  cf t || ( validate_args && login )
  if cf t | grep  "No org or space targeted"; then
    validate_args && login
  fi
  cleanUp
  assert_no_more_leaks

  if  (( errcount > 0 ))
  then
      echo "Test failed with $errcount errors"
  fi
  exit $errcount

}
main
