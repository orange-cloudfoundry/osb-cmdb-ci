#!/usr/bin/env bash
set -euo pipefail # exit on errors

# Exit immediately if a pipeline returns a non-zero status.
#set -o errexit

# If set, any trap on ERR is inherited by shell functions, command substitutions, and commands executed in a subshell environment. The ERR trap is normally not inherited in such cases.
#set -o errtrace

# See https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
# -u The shell shall write a message to standard error when it tries to expand a variable that  is  not set and immediately exit.
# pipefail
#    If set, the return value of a pipeline is the value of the last (rightmost) command to exit with a non-zero status, or zero if all commands in the pipeline exit successfully. This option is disabled by default.

set -x # debug traces
declare -i errcount=0
declare -i errcode=0

readonly API_HOST="${API_HOST:?must be set}"
readonly API_PORT="${API_PORT:?must be set}"
readonly USERNAME="${USERNAME:?must be set}"
readonly PASSWORD="${PASSWORD:?must be set}"
readonly CLIENT_ID="${CLIENT_ID:?must be set}"
readonly CLIENT_SECRET="${CLIENT_SECRET:?must be set}"
readonly DEFAULT_ORG="${DEFAULT_ORG:?must be set}"
readonly DEFAULT_SPACE="${DEFAULT_SPACE:?must be set}"
readonly SKIP_SSL_VALIDATION="${SKIP_SSL_VALIDATION:?must be set}"
readonly GRADLE_ARGS="${GRADLE_ARGS//\$PWD/${PWD}}" # Replace $PWD litteral with content of the PWD env var, ie current build
readonly ARTIFACTORY_URL="${ARTIFACTORY_URL:?must be set}"

# Temporary variables to construct gradle command line
readonly gradle_http_proxy_host=$(echo $http_proxy | sed -E "s#http://(.*):(.+)#\1#")
readonly gradle_http_proxy_port=$(echo $http_proxy | sed -E "s#http://(.*):(.+)#\2#")
readonly gradle_noproxy=$(echo $no_proxy | sed -E "s#,#|#g")
readonly gradle_proxy_config="-Dhttp.proxyHost=${gradle_http_proxy_host} -Dhttps.proxyHost=${gradle_http_proxy_host} -Dhttps.nonProxyHosts=${gradle_noproxy} -Dhttps.proxyPort=${gradle_http_proxy_port} -Dhttp.proxyPort=${gradle_http_proxy_port} -Dhttp.nonProxyHosts=${gradle_noproxy} "

# Inspired from https://raw.githubusercontent.com/spring-io/concourse-java-scripts/v0.0.2/concourse-java.sh
# Setup Maven and Gradle symlinks for caching
setup_symlinks() {
  if [[ -d $PWD/maven && ! -d $HOME/.m2 ]]; then
  ln -s "$PWD/maven" "$HOME/.m2"
  fi
  if [[ -d $PWD/gradle && ! -d $HOME/.gradle ]]; then
  ln -s "$PWD/gradle" "$HOME/.gradle"
  fi
}

build() {
  if [[ $BUILD == "true" ]]; then
    ./gradlew ${gradle_proxy_config} assemble -x test -x javadoc -x sourcesJar -x javadocJar
  else
    echo "Skipping initial build"
  fi
}

# jar file name is versioned yet referenced in env var to be loaded by acceptance tests
# e.g.
# $PWD/osb-cmdb/build/libs/osb-cmdb-1.0.0.jar
# To avoid changing the deployment automation, we simply rename the jar to remove the version
# so that the pipeline var does not need to change upon each release.
# This is easier to be done in this script than in the concourse pipeline yml
rename_jar_file_to_be_predicable() {

  #See inspiration from http://tldp.org/LDP/abs/html/globbingref.html
  #IFS="$(printf '\n\t')"   # Remove space.

  for file in ${PWD}/osb-cmdb/build/libs/osb-cmdb-*.jar ; do         # Use ./* ... NEVER bare *
    echo "renaming $file into $PWD/osb-cmdb/build/libs/osb-cmdb.jar"

    # $ mv --help
    #   -u, --update                 move only when the SOURCE file is newer
    #                                 than the destination file or when the
    #                                 destination file is missing
    mv -u "${file}" "$PWD/osb-cmdb/build/libs/osb-cmdb.jar"
  done

  if [ ! -f  "$PWD/osb-cmdb/build/libs/osb-cmdb.jar" ]; then
    echo "did not find expected jar file at $PWD/osb-cmdb/build/libs/osb-cmdb.jar Exiting"
    exit 1
  fi
}

run_tests() {
  # The AT build.gradle explicitly propagates system properties starting with spring to the test environment


  OSB_CMDB_PROPS=""

  # when set to "true", then the AT properies are exposed. Required for testing osbcmdb dynamic catalog
  if [[ $EXPOSE_AT_PROPS == "true" ]]; then
    # During debug, we once attempted to bypass env variables with JVM properties
    # This was not the root cause, and rather creates divergence with production mechanis using env var
    # with cloudfoundry cf-set-env allow vars separated with dots while bash does not allow it
    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.acceptance-test.cloudfoundry.api-host=${API_HOST}"
    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.acceptance-test.cloudfoundry.api-port=${API_PORT}"
    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.acceptance-test.cloudfoundry.username=${USERNAME}"
    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.acceptance-test.cloudfoundry.password=${PASSWORD}"
    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.acceptance-test.cloudfoundry.client_id=${CLIENT_ID}"
    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.acceptance-test.cloudfoundry.client_secret=${CLIENT_SECRET}"
    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.acceptance-test.cloudfoundry.default-org=${DEFAULT_ORG}"
    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.acceptance-test.cloudfoundry.default-space=${DEFAULT_SPACE}"
    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.acceptance-test.cloudfoundry.skip-ssl-validation=${SKIP_SSL_VALIDATION}"
  fi

  # when set to "true", then the prod env vars are exposed. Required for testing prod environment startup
  if [[ $EXPOSE_PROD_ENV_VARS == "true" ]]; then
    # During debug, we once attempted to bypass env variables with JVM properties
    # This was not the root cause, and rather creates divergence with production mechanis using env var
    # with cloudfoundry cf-set-env allow vars separated with dots while bash does not allow it
#    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.deployer.cloudfoundry.api-host=${API_HOST}"
#    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.deployer.cloudfoundry.api-port=${API_PORT}"
#    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.deployer.cloudfoundry.username=${USERNAME}"
#    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.deployer.cloudfoundry.password=${PASSWORD}"
#    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.deployer.cloudfoundry.client_id=${CLIENT_ID}"
#    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.deployer.cloudfoundry.client_secret=${CLIENT_SECRET}"
#    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.deployer.cloudfoundry.default-org=${DEFAULT_ORG}"
#    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.deployer.cloudfoundry.default-space=${DEFAULT_SPACE}"
#    OSB_CMDB_PROPS="${OSB_CMDB_PROPS} -Dspring.cloud.appbroker.deployer.cloudfoundry.skip-ssl-validation=${SKIP_SSL_VALIDATION}"

    # To check received env in gradle test, use a gradle --debug output which produces the following trace
    # > 10:56:56.188 [DEBUG] [org.gradle.process.internal.DefaultExecHandle] Environment for process 'Gradle Test Executor 1': { [...] }
    export SPRING_CLOUD_APPBROKER_DEPLOYER_CLOUDFOUNDRY_API_HOST="${API_HOST}"
    export SPRING_CLOUD_APPBROKER_DEPLOYER_CLOUDFOUNDRY_API_PORT="${API_PORT}"
    export SPRING_CLOUD_APPBROKER_DEPLOYER_CLOUDFOUNDRY_USERNAME="${USERNAME}"
    export SPRING_CLOUD_APPBROKER_DEPLOYER_CLOUDFOUNDRY_PASSWORD="${PASSWORD}"
    export SPRING_CLOUD_APPBROKER_DEPLOYER_CLOUDFOUNDRY_DEFAULT_ORG="${DEFAULT_ORG}"
    export SPRING_CLOUD_APPBROKER_DEPLOYER_CLOUDFOUNDRY_DEFAULT_SPACE="${DEFAULT_SPACE}"
    export SPRING_CLOUD_APPBROKER_DEPLOYER_CLOUDFOUNDRY_SKIP_SSL_VALIDATION="${SKIP_SSL_VALIDATION}"

  fi
  # when set to "true", then the acceptance test env vars are exposed. Required for launching SCAB AT.
  if [[ $EXPOSE_AT_ENV_VARS == "true" ]]; then
    export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_API_HOST="${API_HOST}"
    export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_API_PORT="${API_PORT}"
    export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_USERNAME="${USERNAME}"
    export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_PASSWORD="${PASSWORD}"
    export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_CLIENT_ID="${CLIENT_ID}"
    export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_CLIENT_SECRET="${CLIENT_SECRET}"
    export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_DEFAULT_ORG="${DEFAULT_ORG}"
    export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_DEFAULT_SPACE="${DEFAULT_SPACE}"
    export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_SKIP_SSL_VALIDATION="${SKIP_SSL_VALIDATION}"
  fi
  export TESTS_BROKERAPPPATH=build/libs/spring-cloud-app-broker-acceptance-tests.jar


  # Don't wait on test error in order to still package test report
  set +e

  ./gradlew ${gradle_proxy_config} ${OSB_CMDB_PROPS} ${GRADLE_ARGS}

  if [[ $? -ne 0 ]]; then
    errcount=$(( errcount + 1 ))
  fi
  set -e
}
load_metadata() {
    # Grab the metadata published by metadata resource
  url=$(cat metadata/atc_external_url)
  team=$(cat metadata/build_team_name)
  pipeline=$(cat metadata/build_pipeline_name)
  job=$(cat metadata/build_job_name)
  build=$(cat metadata/build_name)
}
zip_reports_for_publication() {
  report_file_name="reports_${job}_${build}.tgz"
  echo "packaging found reports into ${report_file_name}"
  # Avoid leading . in the tgz archive which breaks jcr
  # See https://stackoverflow.com/questions/60988334/artifactory-archive-entry-download-404-for-tgz-with-leading-dot-in-path-to-arch
  find . -type d -name "reports" | xargs -n 20 tar cvfz "${report_file_name}" --transform='s|^\./||S'
  report_dirs=$(find . -type d -name "reports")
  index_files=$(for d in $report_dirs; do find $d -name index.html | sed "s|^\./||"; done)

  notif_file_name="notification.md"
  touch ${notif_file_name}
  # Reset content from previous execution to avoid reporting duplicates
  echo > ${notif_file_name}
  # shellcheck disable=SC2129

  # Pull request variant https://github.com/telia-oss/github-pr-resource#get
  if [ -f .git/resource/title ]; then
    printf "\nFrom pr#" >> ${notif_file_name}
    cat .git/resource/pr >> ${notif_file_name}
    printf " with title:\`" >> ${notif_file_name}
    cat .git/resource/title >> ${notif_file_name}
    printf "\`\n" >> ${notif_file_name}
  fi

  printf "\nLast commit has message: \n\`\`\`\n" >> ${notif_file_name}
  # Git resource variant
  if [ -f .git/commit_message ]; then
    cat .git/commit_message >> ${notif_file_name}
  fi
  # Pull request variant https://github.com/telia-oss/github-pr-resource#get
  if [ -f .git/resource/message ]; then
    cat .git/resource/message >> ${notif_file_name}
  fi

  printf "\n\`\`\`\nand hash: \`" >> ${notif_file_name}
  # Git resource variant
  if [ -f .git/ref ]; then
    cat .git/ref >> ${notif_file_name}
  fi
  # Pull request variant https://github.com/telia-oss/github-pr-resource#get
  if [ -f .git/resource/head_sha ]; then
    cat .git/resource/head_sha >> ${notif_file_name}
  fi
  printf "\`" >> ${notif_file_name}

  # shellcheck disable=SC2129
  echo >> ${notif_file_name}

  echo "Gradle [report archive](${ARTIFACTORY_URL}/${report_file_name}) with: " >> ${notif_file_name}
  for f in ${index_files}; do
    #See Artifactory archive entry download specs at https://www.jfrog.com/confluence/display/JFROG/Artifactory+REST+API#ArtifactoryRESTAPI-ArchiveEntryDownload
    echo "* [$f](${ARTIFACTORY_URL}/${report_file_name}!/$f) " >> ${notif_file_name}
  done
  echo "notification content written to ${notif_file_name}"
}
main() {
  setup_symlinks
  load_metadata
  pushd "git-repo" > /dev/null
    build
    rename_jar_file_to_be_predicable
    run_tests
    zip_reports_for_publication
  popd > /dev/null

  if  (( errcount > 0 ))
  then
      echo "Test failed with $errcount errors"
  fi
  exit $errcount

}
main

}