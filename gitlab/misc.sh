#!/bin/sh

[[ -n "$TRACE" ]] && set -x

function load_ssh_agent() {
  # An example of how we could add a deploy key if required
  # eval $(ssh-agent -s)
  # echo "$DEPLOY_KEY_B64_EXAMPLE " | base64 -d | tr -d '\r' | ssh-add - > /dev/null
  # mkdir -p ~/.ssh
  # chmod 700 ~/.ssh
  # ssh-keyscan -H gitlab.com >> ~/.ssh/known_hosts
  true
}

function validate_schemas_kubecfg() {
  local dir
  dir=${1-"rendered"}

  for cluster in \
    $(find $dir -type f -name ClusterIssuer-selfsigning-issuer.yaml -exec dirname {} \;) \
    $(find $dir -type f -name config.yaml -exec dirname {} \;)
  do
    echo "# ---------------------- #"
    echo "# Validating Kustomize with Kubecfg for Cluster $cluster #"
    echo "# ---------------------- #"
    kubecfg validate $(ls $cluster/* | egrep ".yaml|.yml")
  done
}

function validate_schemas_opa() {
  local dir
  dir=${1-"rendered"}

  POLICIES_BRANCH=${POLICIES_BRANCH:-master}

  git clone "https://gitlab-ci-token:${CI_JOB_TOKEN}@${POLICIES_REPO}" -b $POLICIES_BRANCH /tmp/policies

  for cluster in \
    $(find $dir -type f -name ClusterIssuer-selfsigning-issuer.yaml -exec dirname {} \;) \
    $(find $dir -type f -name config.yaml -exec dirname {} \;)
  do
    echo "# ---------------------- #"
    echo "# Testing OPA for Cluster $cluster #"
    echo "# ---------------------- #"
    conftest test $cluster -p /tmp/policies/opa/kustomize/policy
  done
}

function validate_schemas_pluto() {
  local dir
  dir=${1-"rendered"}

  PLUTO_K8S_VERSION="${PLUTO_K8S_VERSION:-1.16.0}"

  for cluster in \
    $(find $dir -type f -name ClusterIssuer-selfsigning-issuer.yaml -exec dirname {} \;) \
    $(find $dir -type f -name config.yaml -exec dirname {} \;)
  do
    echo "# ---------------------- #"
    echo "# Validating Manifests with Pluto for Cluster $cluster #"
    echo "# ---------------------- #"
    pluto detect-files -d $cluster --target-version "k8s=v${PLUTO_K8S_VERSION}" -o wide
  done
}

function check_flux_patch_destination() {
  files=$(git diff --name-only  "origin/${CI_MERGE_REQUEST_TARGET_BRANCH_NAME}"..."origin/${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME}" | grep flux-patch.conf || true)
  for file in $files; do
    echo "Comparing $(echo "$file" | cut -d'/' -f3) and $CI_MERGE_REQUEST_TARGET_BRANCH_NAME"
    if [[ $(echo "$file" | cut -d'/' -f3) == "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" ]]; then
      echo "Detected an attempt to merge a flux-patch.conf for the current branch/environment ($file into the $CI_MERGE_REQUEST_TARGET_BRANCH_NAME branch)"
      exit 1
    fi
  done
}

install_kustomize() {
  if [ -z "$KUSTOMIZE_VERSION" ] || [ -z "$KUSTOMIZE_SHA256" ]; then
    echo "KUSTOMIZE Vars are not defined"
    exit 1
  fi

  echo "Installing Kustomize ${KUSTOMIZE_VERSION}"

  wget -q -O /tmp/kustomize.tar.gz https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz
  cd /tmp
  echo "$KUSTOMIZE_SHA256  kustomize.tar.gz" | sha256sum -c
  cd $CI_PROJECT_DIR
  tar zxvf /tmp/kustomize.tar.gz -C /tmp
  mv /tmp/kustomize /usr/local/bin/kustomize
  chmod +x /usr/local/bin/kustomize
  rm -f /tmp/kustomize.tar.gz
}

install_k8s_yaml_splitter() {
  if [ -z "$K8S_YAML_SPLITTER_VERSION" ] || [ -z "$K8S_YAML_SPLITTER_SHA256" ]; then
    echo "K8S_YAML_SPLITTER Vars are not defined"
    exit 1
  fi

  echo "Installing k8s-yaml-splitter ${K8S_YAML_SPLITTER_VERSION}"

  wget -q -O /tmp/k8s-yaml-splitter https://github.com/mintel/k8s-yaml-splitter/releases/download/v${K8S_YAML_SPLITTER_VERSION}/k8s-yaml-splitter
  cd /tmp
  echo "$K8S_YAML_SPLITTER_SHA256  k8s-yaml-splitter" | sha256sum -c
  mv /tmp/k8s-yaml-splitter /usr/local/bin/k8s-yaml-splitter
  chmod +x /usr/local/bin/k8s-yaml-splitter
  cd $CI_PROJECT_DIR
}


install_golang_yq() {
  if [ -z "$GOLANG_YQ_VERSION" ] || [ -z "$GOLANG_YQ_SHA256" ]; then
    echo "GOLANG_YQ Vars are not defined"
    exit 1
  fi

  echo "Installing Golang YQ ${GOLANG_YQ_VERSION}"

  wget -q -O /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/${GOLANG_YQ_VERSION}/yq_linux_amd64
  chmod +x /usr/local/bin/yq
  cd /usr/local/bin
  echo "$GOLANG_YQ_SHA256  yq" | sha256sum -c
  cd $CI_PROJECT_DIR
}

install_kind() {
  if [ -z "$KIND_VERSION" ] || [ -z "$KIND_SHA256" ]; then
    echo "KIND Vars are not defined"
    exit 1
  fi

  echo "Installing KinD ${KIND_VERSION}"

  wget -q -O /usr/local/bin/kind https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-linux-amd64
  cd /usr/local/bin
  chmod +x /usr/local/bin/kind
  echo "$KIND_SHA256  kind" | sha256sum -c
  cd $CI_PROJECT_DIR
}

install_kubectl() {
  if [ -z "$KUBECTL_VERSION" ] || [ -z "$KUBECTL_SHA256" ]; then
    echo "KUBECTL Vars are not defined"
    exit 1
  fi

  echo "Installing Kubectl ${KUBECTL_VERSION}"

  wget -q -O /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl
  chmod +x /usr/local/bin/kubectl
  cd /usr/local/bin
  echo "$KUBECTL_SHA256  kubectl" | sha256sum -c
  cd $CI_PROJECT_DIR
}

install_kubecfg() {
  if [ -z "$KUBECFG_VERSION" ] || [ -z "$KUBECFG_SHA256" ]; then
    echo "KUBECFG Vars are not defined"
    exit 1
  fi

  echo "Installing Kubecfg ${KUBECFG_VERSION}"

  wget -q -O /usr/local/bin/kubecfg https://github.com/ksonnet/kubecfg/releases/download/v${KUBECFG_VERSION}/kubecfg-linux-amd64
  chmod +x /usr/local/bin/kubecfg
  cd /usr/local/bin
  echo "$KUBECFG_SHA256  kubecfg" | sha256sum -c
  cd $CI_PROJECT_DIR
}

install_conftest() {
  if [ -z "$CONFTEST_VERSION" ] || [ -z "$CONFTEST_SHA256" ]; then
    echo "CONFTEST Vars are not defined"
    exit 1
  fi

  echo "Installing ConfTest ${CONFTEST_VERSION}"

  wget -q https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_x86_64.tar.gz -O /tmp/conftest.tar.gz
  cd /tmp
  echo "$CONFTEST_SHA256  conftest.tar.gz" | sha256sum -c
  tar zxvf /tmp/conftest.tar.gz  -C /tmp
  mv /tmp/conftest /usr/local/bin/conftest
  chmod a+x /usr/local/bin/conftest
  rm -f /tmp/conftest*
  cd $CI_PROJECT_DIR
}

install_vault() {
  if [ -z "$VAULT_VERSION" ] || [ -z "$VAULT_SHA256" ]; then
    echo "VAULT Vars are not defined"
    exit 1
  fi

  echo "Installing Vault ${VAULT_VERSION}"

  wget -q -O /tmp/vault.zip https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip
  cd /tmp
  echo "$VAULT_SHA256  vault.zip" | sha256sum -c
  unzip vault.zip -d /usr/local/bin
  chmod +x /usr/local/bin/vault
  rm -f vault.zip
  cd $CI_PROJECT_DIR
}

install_pluto() {
  if [ -z "$PLUTO_VERSION" ] || [ -z "$PLUTO_SHA256" ]; then
    echo "PLUTO Vars are not defined"
    exit 1
  fi

  echo "Installing Pluto ${PLUTO_VERSION}"

  wget -q https://github.com/FairwindsOps/pluto/releases/download/v${PLUTO_VERSION}/pluto_${PLUTO_VERSION}_linux_amd64.tar.gz -O /tmp/pluto.tar.gz
  echo "$PLUTO_SHA256 /tmp/pluto.tar.gz" | sha256sum -c
  tar zxvf /tmp/pluto.tar.gz -C /tmp
  install /tmp/pluto /usr/local/bin/pluto
  rm -f /tmp/pluto.tar.gz
  cd $CI_PROJECT_DIR
}

alpine_install_pkg() {
  apk add --no-cache $@
}

alpine_prepare_golden_diff() {
  alpine_install_pkg git make bash findutils

  install_kustomize
  install_golang_yq
  install_k8s_yaml_splitter
}

alpine_prepare_kind_job() {
  alpine_install_pkg docker-cli coreutils git

  install_kind
  install_kubectl
  install_kubecfg
}

alpine_prepare_opa_job() {
  alpine_install_pkg findutils git coreutils

  install_conftest
}

alpine_prepare_vault_job() {
  alpine_install_pkg findutils git coreutils docker-cli tree

  install_golang_yq
  install_vault
  install_kustomize
}

alpine_prepare_pluto_job() {
  alpine_install_pkg findutils git coreutils libc6-compat

  install_pluto
}

alpine_prepare_jsonnet_job() {
  alpine_install_pkg jsonnet make findutils bash
}

alpine_prepare_k8sbootstrap_golden_diff() {
  alpine_install_pkg make git bash

  install_kubecfg
}

alpine_prepare_k8sbootstrap_kind_job() {
  alpine_install_pkg docker-cli coreutils git

  install_kind
  install_kubectl
  install_kubecfg
}

alpine_prepare_k8sbootstrap_opa_job() {
  alpine_install_pkg findutils git coreutils

  install_conftest
  install_kubecfg
}
