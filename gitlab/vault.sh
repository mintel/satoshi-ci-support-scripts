[[ "$TRACE" ]] && set -x

DOCKER_HOST_ALIAS="${DOCKER_HOST_ALIAS:-docker}"
VAULT_VERSION="${VAULT_VERSION:-1.3.2}"
VAULT_DEV_ROOT_TOKEN="${VAULT_DEV_ROOT_TOKEN:-e59546c1-3383-497a-8024-aaf2a400064a}"
BANK_VAULTS_IMAGE="${BANK_VAULTS_IMAGE:-banzaicloud/bank-vaults}"
BANK_VAULTS_VERSION="${BANK_VAULTS_VERSION:-0.9.0}"
#GITOPS_CI_CONTAINER_IMAGE="${GITOPS_CI_CONTAINER_IMAGE:-mintel/satoshi-gitops-ci}"
#GITOPS_CI_CONTAINER_VERSION="${GITOPS_CI_CONTAINER_VERSION:-0.9.0}"

CONFS_DIR="/tmp/confs"

function extract_vault_configs_from_manifests {
  mkdir -p $CONFS_DIR

  env_dir="${CI_PROJECT_DIR}/rendered/environments/$ENV/vault"
  configmaps=$(grep -l "app: vault-configurator" $env_dir/ConfigMap* || true)
  secrets=$(grep -l "app:vault-configurator" $env_dir/Secret* || true)

  for file in $configmaps $secrets; do
    skip_ci=$(yq read $file 'metadata.annotations."mintel.com/skip-local-ci"')
    [[ $skip_ci == "true" ]] && echo "EXLCUDING: $file - skip-ci annotation" && continue

    data=$(yq read $file 'data."vault-config.yml"' | base64 -w0)
    [[ $data == "bnVsbAo=" ]] && echo "EXLCUDING: $file - not a vault-config.yml key" && continue

    kind=$(yq read $file 'kind')
    name=$(basename $file)

    if [[ $kind == "ConfigMap" ]]; then
      yq read $file 'data."vault-config.yml"' > $CONFS_DIR/$name
    elif [[ $kind == "Secret" ]]; then
      yq read $file 'data."vault-config.yml"' | base64 -d > $CONFS_DIR/$name
    fi
  done
}

function build_bank_vaults_configs_list {
  local CONFS_STRING=""

  for file in `ls $CONFS_DIR`; do
    CONFS_STRING="${CONFS_STRING}--vault-config-file=$CONFS_DIR/${file} "
  done

  echo $CONFS_STRING
}

function check_vault_policies() {
  set -e
  docker pull $BANK_VAULTS_IMAGE:$BANK_VAULTS_VERSION  | grep -e 'Pulling from' -e Digest -e Status -e Error
  docker run --rm --entrypoint cat $BANK_VAULTS_IMAGE:$BANK_VAULTS_VERSION -- /usr/local/bin/bank-vaults > /usr/local/bin/bank-vaults
  chmod a+x /usr/local/bin/bank-vaults

  printf "\n##########################################################"
  printf "\n## extracting Policies from manifests "
  printf "\n##########################################################\n"

  extract_vault_configs_from_manifests
  tree $CONFS_DIR

  printf "\n##########################################################"
  printf "\n## Testing policies for $ENV Environments"
  printf "\n##########################################################\n"

  printf "\n## Starting Configurator ##\n"
  local CONFS
  CONFS=$(build_bank_vaults_configs_list)

  bank-vaults configure --once --fatal --mode dev $CONFS

  printf "\n## Status ##\n"
  vault status

  printf "\n## Policies ##\n"
  vault policy list

  printf "\n## Secrets ##\n"
  vault secrets list

  printf "\n## Auth ##\n"
  vault auth list

  printf "\n##########################################################\n"

}
