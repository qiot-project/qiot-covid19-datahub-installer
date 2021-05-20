# qiot-covid19-datahub-installer
This is the installer project for the qIoT data hub. The main purpose of this project is to easily install a fresh environment in an OpenShift cluster (4.6+).

## What it does?
The script will do the following:
- Creating [prefix]-datahub namespace
- Creating a cert-manager namespace
- Creating [prefix]-(dev|int|prod) namespaces
- It will then git clone into qiot-covid19-datahub-operators repo
- It will then git clone into qiot-covid19-datahub-pipelines repo
- From the operators repo, it will helm package all charts into /tmp/datahub/charts folder
  - PostgreSQL
  - InfluxDB2
  - cert-manager
  - vault
  - grafana
  - nexus
  - AMQ Broker
- From the pipelines repo, it will call the build-chart.sh script and will copy the resulting chart into /tmp/datahub/charts
- It will then install and configure hashicorp/vault
- Then it will install and configure cert-manager
- It will then install the vault-issuer chart into all namespaces 
- Then it will install all the charts from /tmp/datahub/charts in the following order into the datahub namespace
  - nexus
  - influxdb2
  - postgreSQL
  - grafana
  - AMQ Broker
  - pipelines



## Installing everything
This script is meant to be called from a client machine (macOS or Linux):

```bash
$ ./datahub-install.sh
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
      -p|--project-prefix [string]   Prefix to be added to datahub project names e.g. PREFIX-datahub (default: covid19)
      -t|--temporary-dir [string]    Define the tmp dir for work (default: /tmp/datahub)
      -d|--base-domain [string]      Define the base domain for all routes (default: apps-crc.testing)
      -v|--vault-host-name [string]  Define the internal host name of the vault (default: vault)
      -r|--dry-run                   Prepare the setup only, do not install anything

  NOTES:
      - External vault host will be https://VAULT_HOST_NAME.BASE_DOMAIN/
      - Internal vault address will be https://VAULT_HOST_NAME.svc.cluster.local:8200
```

The easiest way to install the datahub would be

```bash
$ oc login -u kubeadmin https://api.crc.testing:6443
$ ./datahub-install.sh install 
```

This would install everything with PREFIX 'covid19', temporary directory '/tmp/datahub' and base domain 'apps-crc.testing'. 


## Uninstalling everything
Simply call the script with uninstall command
```bash
$ ./datahub-install.sh uninstall 
```

Please note that you must use the same --project-prefix as you've been using during install.

## NOTE
YOU MUST BE LOGGED INTO AN OPENSHIFT CLUSTER WITH cluster-admin role!

