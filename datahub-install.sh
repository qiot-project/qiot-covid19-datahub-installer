#!/bin/bash
#
# This script installs the covid19 datahub into an existing OpenShift cluster > 4.6
#

set -e -u -o pipefail
declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PRJ_PREFIX="covid19"
declare COMMAND="help"
declare TMP="/tmp/datahub"

VAULT_KEY=
VAULT_TOKEN=

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
declare -r charts="$TMP/charts"
declare -r ca=$TMP/ca


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

install_certmanager() {
    info "Installing cert-manager into cert-manager namespace"
    oc get ns cert-manager 2>/dev/null || {
        info "Installing cert-manager into cert-manager namespace"
        oc new-project cert-manager >/dev/null
    }
    
    helm repo add jetstack https://charts.jetstack.io
    helm repo update

    helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --version v1.2.0 --set installCRDs=true
    oc apply -f $git_operators/cert-manager/sample/test-resource.yaml -n cert-manager

    info "Generating keys..."
    openssl req -new -nodes -newkey rsa:2048 -x509 -keyout $ca/tls.key -out $ca/tls.crt -days 365 -subj "/CN=qiot-project.github.io" -extensions v3_ca
    oc create secret generic qiot-ca --from-file=$ca/ -n cert-manager

    info ""
    oc apply -f $git_operators/sample/issuer-qiot-ca-sample.yaml -n cert-manager
    oc apply -f $git_operators/sample/certificate-qiot-device-sample.yaml -n cert-manager

    # From here, we have to have a working vault installed

}

install_vault() {
    info "Installing hashicorp/vault into cert-manager namespace"
    oc get ns cert-manager 2>/dev/null || {
        oc new-project cert-manager >/dev/null
    }

    helm repo add hashicorp https://helm.releases.hashicorp.com
    helm repo update
    helm upgrade --install vault hashicorp/vault --namespace cert-manager -f $git_operators/vault/override-standalone.yaml

    info "Configuring hashicorp/vault..."
    
    # copy policy.hcl and script to pod
    cp scripts/configure-vault.sh $git_operators/vault/sample/
    oc get pod
    oc rsync $git_operators/vault/sample/ vault-0:/tmp/
 
    # execute that script on pod
    oc exec vault-0 -- sh /tmp/configure-vault.sh > $TMP/configure-vault.out

    # grep output to get VAULT_KEY and VAULT_TOKEN
    VAULT_KEY=$(cat $TMP/configure-vault.out | grep "Exported KEY: " | cut -d' ' -f 3)
    VAULT_TOKEN=$(cat $TMP/configure-vault.out | grep "Exported TOKEN: " | cut -d' ' -f 3)

    [ -z $VAULT_KEY ] && err "Could not determine VAULT_KEY. Exiting. Please rerun again."
    [ -z $VAULT_TOKEN ] && err "Could not determine VAULT_TOKEN. Exiting. Please rerun again."

    info "Vault successfully installed!"
    info "VAULT_KEY   = $VAULT_KEY"
    info "VAULT_TOKEN = $VAULT_TOKEN"

}


# Install all the charts and configure the system
command.install() {
    oc version >/dev/null 2>&1 || err "no oc binary found"
    helm version >/dev/null 2>&1 || err "no helm binary found!"
    openssl version >/dev/null 2>&1 || err "no openssl binary found!"

    kube_context=$(oc whoami -c)
    info "Using $kube_context to install datahub..."

    info "Creating namespace for $PRJ_PREFIX datahub..."
    oc get ns $project_name 2>/dev/null  || { 
        oc new-project $project_name >/dev/null 
        info "$project_name created"
    }

    info "Cloning corresponding repositories from GitHub..."
    git version >/dev/null 2>&1 || err "no git binary found"

    # delete tmp folders if exists
    [ -d "$git_operators" ] && rm -rf "$git_operators"
    [ -d "$git_pipelines" ] && rm -rf "$git_pipelines"
    [ -d "$charts" ] && rm -rf "$charts"
    [ -d "$ca" ] && rm -rf "$ca"

    mkdir -p $git_pipelines
    mkdir -p $git_operators
    mkdir -p $charts
    mkdir -p $ca
    git clone https://github.com/qiot-project/qiot-covid19-datahub-operators.git $git_operators >/dev/null
    git clone https://github.com/qiot-project/qiot-covid19-datahub-pipelines.git $git_pipelines >/dev/null
    

    # First the easy part: Generate the pipelines chart... this is easy, just call a script.
    info "Generating helm chart for pipelines..."
    $git_pipelines/build-chart.sh
    mv $git_pipelines/target/qiot-covid19-datahub-pipelines*.tgz $charts/

    # Generate all the other charts from $git_operators folder
    info "Generating Nexus chart..."
    helm package $git_operators/nexus -u -d $charts

    info "Generating PostgreSQL chart..."
    helm package $git_operators/postgreSQL -u -d $charts

    info "Generating InfluxDB2 chart..."
    helm package $git_operators/influxdb2 -u -d $charts

    info "Generating Grafana chart..."
    helm package $git_operators/Grafana -u -d $charts

    # Now install cert-manager
    install_vault
    install_certmanager
} 

command.uninstall() {
    oc version >/dev/null 2>&1 || err "no oc binary found"
    helm version >/dev/null 2>&1 || err "no helm binary found!"

    kube_context=$(oc whoami -c)
    info "Using $kube_context to uninstall datahub..."

    oc delete project cert-manager
    oc delete project $project_name

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