    #!/bin/bash
    # This script will be copied to the vault-0 pod after installing
    # hashicorp/vault 
    #
    # It will configure the vault with everything required.
    # It expeects a policy.hcl file in /tmp on the pod
    #
    echo "Configuring vault on pod"
    vault operator init -tls-skip-verify -key-shares=1 -key-threshold=1 > /tmp/vault.txt
    export KEYS=$(cat /tmp/vault.txt | head -n 1 | cut -d' ' -f 4)
    export VAULT_TOKEN=$(cat /tmp/vault.txt | head -n3|tail -n1|cut -d' ' -f4)

    # unseal 
    vault operator unseal -tls-skip-verify $KEYS

    # enable pki engine
    vault secrets enable -tls-skip-verify --path=cert-manager-io pki
    vault secrets tune -tls-skip-verify -max-lease-ttl=8760h cert-manager-io
    vault write -tls-skip-verify cert-manager-io/root/generate/internal common_name=qiot-project.github.io ttl=8760h

    # CRL configuration
    vault write -tls-skip-verify cert-manager-io/config/urls issuing_certificates="https://127.0.0.1:8200/v1/cert-manager-io/ca" crl_distribution_points="https://127.0.0.1:8200/v1/cert-manager-io/crl"

    # Configure Domain for qiot-project.github.io
    vault write -tls-skip-verify cert-manager-io/roles/qiot-project-github-io allowed_domains=qiot-project.github.io,svc allow_subdomains=true allowed_other_sans="*" allow_glob_domains=true max_ttl=72h

    # Enable Kubernetes Auth
    JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    KUBERNETES_HOST=https://${KUBERNETES_PORT_443_TCP_ADDR}:443

    vault auth enable --tls-skip-verify kubernetes
    vault write --tls-skip-verify auth/kubernetes/config token_reviewer_jwt=$JWT kubernetes_host=$KUBERNETES_HOST kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

    # Create PKI policy
    vault policy write --tls-skip-verify pki-policy /tmp/sample/policy.hcl

    # Authorize Cert-manager
    vault write --tls-skip-verify auth/kubernetes/role/cert-manager bound_service_account_names=cert-manager bound_service_account_namespaces='cert-manager' policies=pki-policy ttl=2h

    echo "Exported KEY: $KEYS"
    echo "Exported TOKEN: $VAULT_TOKEN"
