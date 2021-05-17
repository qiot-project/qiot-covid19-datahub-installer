#!/bin/bash
#
# This script installs the covid19 datahub into an existing OpenShift cluster > 4.6
#

set -e -u -o pipefail
declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PRJ_PREFIX="covid19"
declare COMMAND="help"
declare TMP="/tmp/datahub"


valid_command() {
  local fn=$1; shift
  [[ $(type -t "$fn") == "function" ]]
}

info() {
    printf "\n# INFO: $@\n"
}

err() {
  printf "\n# ERROR: $1\n"
  exit 1
}

while (( "$#" )); do
  case "$1" in
    install|uninstall)
      COMMAND=$1
      shift
      ;;
    -p|--project-prefix)
      PRJ_PREFIX=$2
      shift 2
      ;;
    -t|--temporary-dir)
      TMP=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*|--*)
      err "Error: Unsupported flag $1"
      ;;
    *) 
      break
  esac
done

declare -r project_name=$PRJ_PREFIX-datahub
declare -r git_pipelines="$TMP/pipelines"
declare -r git_operators="$TMP/operators"


command.help() {
  cat <<-EOF
  Install and configure the datahub OpenShift project from scratch.
  
  Usage:
      datahub-install [command] [options]
  
  Example:
      datahub-install install --project-prefix covid19
  
  COMMANDS:
      install                        Sets up the the complete datahub environment
      uninstall                      Deletes the complete datahub environment
      help                           Help about this command

  OPTIONS:
      -p|--project-prefix [string]   Prefix to be added to datahub project names e.g. PREFIX-datahub (covid19-datahub)
      -t|--temporary-dir [string]    Define the tmp dir for work (default: $TMP)

EOF
}

command.install() {
    oc version >/dev/null 2>&1 || err "no oc binary found"
    helm version >/dev/null 2>&1 || err "no helm binary found!"

    kube_context=$(oc whoami -c)
    info "Using $kube_context to install datahub..."

    info "Creating namespace for $PRJ_PREFIX datahub..."
    oc get ns $project_name 2>/dev/null  || { 
        oc new-project $project_name
        info "$project_name created"
    }

    info "Cloning corresponding repositories from GitHub..."
    git version >/dev/null 2>&1 || err "no git binary found"

    # delete tmp folders if exists
    [ -d "$git_operators" ] && rm -rf "$git_operators"
    [ -d "$git_pipelines" ] && rm -rf "$git_pipelines"

    mkdir -p $git_pipelines
    mkdir -p $git_operators
    git clone https://github.com/qiot-project/qiot-covid19-datahub-operators.git $git_operators
    git clone https://github.com/qiot-project/qiot-covid19-datahub-pipelines.git $git_pipelines
    

    # First the easy part: Generate the pipelines chart... this is easy, just call a script.
    info "Generating helm chart for pipelines..."
    $git_pipelines/build-chart.sh


} 


main() {
  local fn="command.$COMMAND"
  valid_command "$fn" || {
    err "invalid command '$COMMAND'"
  }

  cd $SCRIPT_DIR
  $fn
  return $?
}

main