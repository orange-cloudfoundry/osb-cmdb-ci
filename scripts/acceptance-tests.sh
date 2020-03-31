#!/usr/bin/env bash
set -euo pipefail
set -x # debug traces

readonly API_HOST="${API_HOST:?must be set}"
readonly API_PORT="${API_PORT:?must be set}"
readonly USERNAME="${USERNAME:?must be set}"
readonly PASSWORD="${PASSWORD:?must be set}"
readonly CLIENT_ID="${CLIENT_ID:?must be set}"
readonly CLIENT_SECRET="${CLIENT_SECRET:?must be set}"
readonly DEFAULT_ORG="${DEFAULT_ORG:?must be set}"
readonly DEFAULT_SPACE="${DEFAULT_SPACE:?must be set}"
readonly SKIP_SSL_VALIDATION="${SKIP_SSL_VALIDATION:?must be set}"
readonly GRADLE_ARGS="${GRADLE_ARGS:?must be set}"

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
  ./gradlew ${gradle_proxy_config} assemble -x test -x javadoc -x docsZip -x sourcesJar -x javadocJar -x distZip
}
run_tests() {
  export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_API_HOST="${API_HOST}"
  export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_API_PORT="${API_PORT}"
  export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_USERNAME="${USERNAME}"
  export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_PASSWORD="${PASSWORD}"
  export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_CLIENT_ID="${CLIENT_ID}"
  export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_CLIENT_SECRET="${CLIENT_SECRET}"
  export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_DEFAULT_ORG="${DEFAULT_ORG}"
  export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_DEFAULT_SPACE="${DEFAULT_SPACE}"
  export SPRING_CLOUD_APPBROKER_ACCEPTANCETEST_CLOUDFOUNDRY_SKIP_SSL_VALIDATION="${SKIP_SSL_VALIDATION}"
  export TESTS_BROKERAPPPATH=build/libs/spring-cloud-app-broker-acceptance-tests.jar
  ./gradlew ${gradle_proxy_config} ${GRADLE_ARGS}
}
main() {
  setup_symlinks
  pushd "git-repo" > /dev/null
    build
    run_tests
  popd > /dev/null
}
main
