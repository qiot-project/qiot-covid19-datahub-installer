#!/bin/bash
#
# This script installs the covid19 datahub into an existing OpenShift cluster > 4.6
#

set -e -u -o pipefail
declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PRJ_PREFIX="covid19"
declare COMMAND="help"
declare TMP="/tmp/datahub"
declare BASE_DOMAIN="apps-crc.testing"

VAULT_KEY=
VAULT_TOKEN=

valid_command() {
  local fn=$1; shift
  [[ $(type -t "$fn") == "function" ]]
}

info() {
    printf "# INFO: $@\n"
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
    -d|--base-domain)
      BASE_DOMAIN=$2
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
declare -r dev_proj=$PRJ_PREFIX-dev
declare -r int_proj=$PRJ_PREFIX-int
declare -r prod_proj=$PRJ_PREFIX-prod

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
      -p|--project-prefix [string]   Prefix to be added to datahub project names e.g. PREFIX-datahub (default: $PRJ_PREFIX)
      -t|--temporary-dir [string]    Define the tmp dir for work (default: $TMP)
      -d|--base-domain [string]      Define the base domain for all routes (default: $BASE_DOMAIN)

EOF
}

install_certmanager() {
    info "Installing cert-manager into cert-manager namespace"
    oc get ns cert-manager 2>/dev/null || {
        info "Installing cert-manager into cert-manager namespace"
        oc new-project cert-manager >/dev/null
    }
    
    helm repo add jetstack https://charts.jetstack.io > /dev/null
    helm repo update > /dev/null

    helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --version v1.2.0 --set installCRDs=true > /dev/null
    sleep 10

    info "Generating keys..."
    openssl req -new -nodes -newkey rsa:2048 -x509 -keyout $ca/tls.key -out $ca/tls.crt -days 365 -subj "/CN=qiot-project.github.io" -extensions v3_ca
    oc create secret generic qiot-ca --from-file=$ca/ -n cert-manager

    # we need to wait until everything is settled. Otherwise we can't 
    sleep 20

    oc apply -f $git_operators/cert-manager/sample/issuer-qiot-ca-sample.yaml -n cert-manager
    oc apply -f $git_operators/cert-manager/sample/certificate-qiot-device-sample.yaml -n cert-manager

    # From here, we have to have a working vault installed
    [ -z $VAULT_KEY ] && err "Could not determine VAULT_KEY. Exiting. Please rerun again."
    [ -z $VAULT_TOKEN ] && err "Could not determine VAULT_TOKEN. Exiting. Please rerun again."

    oc apply -f $git_operators/cert-manager/sample/issuer-qiot-vault-sample.yaml -n cert-manager
    oc apply -f $git_operators/cert-manager/sample/certificate-qiot-device-vault-issuer.yaml -n cert-manager

    # get vault address
    export VAULT_ADDR=https://$(oc get route vault --no-headers -o custom-columns=HOST:.spec.host -n cert-manager)
    export KEYS=$VAULT_KEY

    # configure all the projects
    sh $git_operators/cert-manager/covid19/setup.sh $project_name $BASE_DOMAIN
    sh $git_operators/cert-manager/covid19/setup.sh $dev_proj $BASE_DOMAIN
    sh $git_operators/cert-manager/covid19/setup.sh $int_proj $BASE_DOMAIN
    sh $git_operators/cert-manager/covid19/setup.sh $prod_proj $BASE_DOMAIN

    # install helm chart for covid19 issuer in each project
    helm upgrade --install vault $charts/covid19-issuer-0.1.0.tgz -n $project_name > /dev/null
    helm upgrade --install vault $charts/covid19-issuer-0.1.0.tgz -n $dev_proj > /dev/null
    helm upgrade --install vault $charts/covid19-issuer-0.1.0.tgz -n $int_proj > /dev/null
    helm upgrade --install vault $charts/covid19-issuer-0.1.0.tgz -n $prod_proj > /dev/null

    # install helm chart for covid19 issuer in each project
    helm upgrade --install vault $charts/covid19-issuer-0.1.0.tgz -n $project_name --set issuer.create=true > /dev/null
    helm upgrade --install vault $charts/covid19-issuer-0.1.0.tgz -n $dev_proj --set issuer.create=true > /dev/null
    helm upgrade --install vault $charts/covid19-issuer-0.1.0.tgz -n $int_proj --set issuer.create=true > /dev/null
    helm upgrade --install vault $charts/covid19-issuer-0.1.0.tgz -n $prod_proj --set issuer.create=true > /dev/null

}

install_vault() {
    info "Installing hashicorp/vault into cert-manager namespace"
    oc get ns cert-manager 2>/dev/null || {
        oc new-project cert-manager >/dev/null
    }

    helm repo add hashicorp https://helm.releases.hashicorp.com > /dev/null
    helm repo update > /dev/null

    # replace hard coded hostname in override-standalone.yaml
    helm upgrade --install vault hashicorp/vault --namespace cert-manager -f $git_operators/vault/override-standalone.yaml --set server.route.host=vault.$BASE_DOMAIN > /dev/null

    info "Configuring hashicorp/vault..."
    
    # copy policy.hcl and script to pod
    cp scripts/configure-vault.sh $git_operators/vault/sample/
    oc get pod
    sleep 10
    oc rsync $git_operators/vault/sample/ vault-0:/tmp/
 
    # execute that script on pod
    oc exec vault-0 -- sh /tmp/configure-vault.sh > $TMP/configure-vault.out

    # grep output to get VAULT_KEY and VAULT_TOKEN
    VAULT_KEY=$(cat $TMP/configure-vault.out | grep "Exported KEY: " | cut -d' ' -f 3)
    VAULT_TOKEN=$(cat $TMP/configure-vault.out | grep "Exported TOKEN: " | cut -d' ' -f 3)

    [ -z $VAULT_KEY ] && err "Could not determine VAULT_KEY. Exiting. Please rerun again."
    [ -z $VAULT_TOKEN ] && err "Could not determine VAULT_TOKEN. Exiting. Please rerun again."

    info "Vault successfully installed!"
    echo "VAULT_KEY   = $VAULT_KEY"
    echo "VAULT_TOKEN = $VAULT_TOKEN"

}


# Install all the charts and configure the system
command.install() {
    oc version >/dev/null 2>&1 || err "No oc binary found"
    helm version >/dev/null 2>&1 || err "No helm binary found!"
    openssl version >/dev/null 2>&1 || err "No openssl binary found!"
    vault version >/dev/null 2>&1 || err "No vault binary found! Please install from https://vaultproject.io"


    kube_context=$(oc whoami -c)
    info "Using $kube_context to install datahub..."

    info "Creating namespace for $PRJ_PREFIX datahub..."
    oc get ns $project_name 2>/dev/null  || { 
        oc new-project $project_name >/dev/null 
        info "$project_name created"
    }

    oc get ns $dev_proj 2>/dev/null  || { 
        oc new-project $dev_proj >/dev/null 
        info "$dev_proj created"
    }

    oc get ns $int_proj 2>/dev/null  || { 
        oc new-project $int_proj >/dev/null 
        info "$int_proj created"
    }

    oc get ns $prod_proj 2>/dev/null  || { 
        oc new-project $prod_proj >/dev/null 
        info "$prod_proj created"
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

    info "Generating Covid19-Issuer chart..."
    helm package $git_operators/cert-manager/covid19/helm-charts/covid19-issuer -u -d $charts

    # Now install cert-manager
    install_vault
    install_certmanager
} 

command.uninstall() {
    oc version >/dev/null 2>&1 || err "no oc binary found"
    helm version >/dev/null 2>&1 || err "no helm binary found!"

    kube_context=$(oc whoami -c)
    info "Using $kube_context to uninstall datahub..."

    oc get ns cert-manager 2>/dev/null && { 
      info "Deleting cert-manager project"
      oc delete project cert-manager
    }

    oc get ns $project_name 2>/dev/null && { 
      info "Deleting $project_name project"
      oc delete project $project_name
    }

    oc get ns $dev_proj 2>/dev/null && { 
      info "Deleting $dev_proj project"
      oc delete project $dev_proj
    }

    oc get ns $int_proj 2>/dev/null && { 
      info "Deleting $int_proj project"
      oc delete project $int_proj
    }

    oc get ns $prod_proj 2>/dev/null && { 
      info "Deleting $prod_proj project"
      oc delete project $prod_proj
    }
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