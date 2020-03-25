[[ "$TRACE" ]] && set -x

DOCKER_HOST_ALIAS="${DOCKER_HOST_ALIAS:-docker}"
VAULT_VERSION="${VAULT_VERSION:-1.3.2}"
VAULT_DEV_ROOT_TOKEN="${VAULT_DEV_ROOT_TOKEN:-e59546c1-3383-497a-8024-aaf2a400064a}"
BANK_VAULTS_IMAGE="${BANK_VAULTS_IMAGE:-banzaicloud/bank-vaults}"
BANK_VAULTS_VERSION="${BANK_VAULTS_VERSION:-0.9.0}"
#GITOPS_CI_CONTAINER_IMAGE="${GITOPS_CI_CONTAINER_IMAGE:-mintel/satoshi-gitops-ci}"
#GITOPS_CI_CONTAINER_VERSION="${GITOPS_CI_CONTAINER_VERSION:-0.9.0}"
POLICIES_DIR="${POLICIES_DIR}"

CONFS_DIR="/tmp/confs"

[[ -z $POLICIES_DIR ]] && ( printf "\n\nPOLICIES_DIR Undefined\n" && exit 1 )

function extract_vault_configs_from_manifests {
  mkdir -p $CONFS_DIR

  # render all kustomize policies

  #for k in $(find $POLICIES_DIR -type f -name kustomization.yaml); do
  for k in $(find $POLICIES_DIR/$ENV -type f -name kustomization.yaml); do
    env="$(dirname $k | rev | cut -d/ -f1 | rev)"

    mkdir -p $CONFS_DIR/$env/kustomize
    mkdir -p $CONFS_DIR/$env/yamls
    kustomize build $(dirname $k) > $CONFS_DIR/$env/kustomize/manifests.yaml

    file=$CONFS_DIR/$env/kustomize/manifests.yaml
    N_DOCS=$(cat $file | egrep ^kind | wc -l)

    let N_DOCS-=1

    for DOC in `seq 0 $N_DOCS`
    do
      kind=$(yq read -d $DOC $file kind)
      skip_ci=$(yq read -d $DOC $file 'metadata.annotations."mintel.com/skip-local-ci"')

      name=$(yq read -d $DOC $file metadata.name)
      namespace=$(yq read -d $DOC $file metadata.namespace)
      data=$(yq read -d $DOC $file 'data."vault-config.yml"')

      file_name="${namespace}_${name}.yaml"

      [[ $kind == "SealedSecret" ]] && echo "EXCLUDING: $namespace-$name - SealedSecret" && continue
      [[ $skip_ci == "true" ]] && echo "EXLCUDING: $namespace-$name - skip-ci annotation" && continue
      [[ $data == "null" ]] && echo "EXLCUDING: $namespace-$name - not a vault-config.yml key" && continue

      if [[ $kind == "ConfigMap" ]]; then
        yq read -d $DOC $file 'data."vault-config.yml"' > $CONFS_DIR/$env/yamls/${file_name}
      elif [[ $kind == "Secret" ]]; then
        yq read -d $DOC $file 'data."vault-config.yml"' | base64 -d > $CONFS_DIR/$env/yamls/${file_name}
      fi
    done

  done
}

function build_bank_vaults_configs_list {
  local e=$1
  local CONFS_STRING=""

  for file in `ls -1 $CONFS_DIR/$e/yamls`; do
    CONFS_STRING="${CONFS_STRING}--vault-config-file=$CONFS_DIR/$e/yamls/${file} "
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
  CONFS=$(build_bank_vaults_configs_list $env)

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
