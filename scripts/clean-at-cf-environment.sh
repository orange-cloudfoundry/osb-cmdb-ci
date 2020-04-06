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
  readonly API_HOST="${API_HOST:?must be set}"
  readonly API_PORT="${API_PORT:?must be set}"
  readonly USERNAME="${USERNAME:?must be set}"
  readonly PASSWORD="${PASSWORD:?must be set}"
  readonly DEFAULT_ORG="${DEFAULT_ORG:?must be set}"
  readonly DEFAULT_SPACE="${DEFAULT_SPACE:?must be set}"
  readonly SKIP_SSL_VALIDATION="${SKIP_SSL_VALIDATION:?must be set}"
}

login () {
  cf login --skip-ssl-validation  -a "${API_HOST}" -o "$DEFAULT_ORG" -s "$DEFAULT_SPACE" -u "$USERNAME" -p "$PASSWORD"
}

cleanUp() {
  AT_BROKERS=$(cf service-brokers | grep test-broker | awk '{print $1}')
  echo "Cleaning up app broker left overs: [${AT_BROKERS}]"
  for b in ${AT_BROKERS}; do
    SERVICE_DEFINITIONS=$(cf service-access -b $b | tail -n +4 | awk '{print $1}')
        echo "Purging services [${SERVICE_DEFINITIONS}] for broker $b"
        for s in ${SERVICE_DEFINITIONS}; do
          cf purge-service-offering -f -b $b $s
        done
        cf delete-service-broker -f $b
  done
  APPS=$( cf a | tail -n +5 | awk '{print $1}')
  echo "Deleting apps [$APPS]"
  for a in ${APPS}; do
    cf d -f $a
  done
  SERVICE_INSTANCES=$( cf s | tail -n +5 | awk '{print $1}')
  echo "Deleting services [$SERVICE_INSTANCES]"
  for s in ${SERVICE_INSTANCES} ; do
    cf ds -f $s
  done;
}

assert_no_more_leaks() {
  echo "You may check there is no remaining left over"
  cf s
  cf a

  echo "Making sure that there is no brokers left over"
  cf service-brokers > brokers.txt

  grep test-broker- brokers.txt
  if [[ $? -ne 1 ]]; then
      echo "Unexpected uncleaned up broker:"
      cat brokers.txt
      exit 1
  fi

  echo "Making sure that there is no service definition left over in ocmb brokered services"

  OSB_CMDB_BROKERS=$(cat brokers.txt | grep cmdb | awk '{print $1}')
  for b in $OSB_CMDB_BROKERS; do
    cf service-access -b $b > service-access.txt
    for p in app-service backing-service; do
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
  validate_args
  login
  cleanUp
  assert_no_more_leaks

  if  (( errcount > 0 ))
  then
      echo "Test failed with $errcount errors"
  fi
  exit $errcount

}
main
