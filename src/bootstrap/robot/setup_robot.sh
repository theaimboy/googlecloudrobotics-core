#!/bin/bash
#
# Copyright 2019 The Cloud Robotics Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script is a convenience wrapper for starting the setup-robot container, i.e., for doing
# "kubectl run ... --image=...setup-robot...".

set -e
set -o pipefail

function kc {
  kubectl --context="${KUBE_CONTEXT}" "$@"
}

function faketty {
  # Run command inside a TTY.
  script -qfec "$(printf "%q " "$@")" /dev/null
}

if [[ ! "$*" =~ "--project" && $# -ge 2 ]] ; then
  echo "WARNING: using only positional arguments for setup_robot.sh is deprecated." >&2
  echo "    Please use the following invocation instead. Setup continues in 60 seconds..." >&2
  echo "    setup-robot <robot-name> --project <project-id> \\" >&2
  echo "        [--robot-type <type>] [--app-management]" >&2
  # Sleep, as the warning can't be seen after the helm output fills the screen.
  sleep 60
  # Rewrite parameters to new usage.
  set -- "$2" --project "$1" --robot-type "${3:-}"
fi

# Extract the project from the command-line args. It is required to identify the reference for the
# setup-robot image. This is challenging as --project is an option, so we have to do some
# rudimentary CLI parameter parsing.
for i in $(seq 1 $#) ; do
  if [[ "${!i}" == "--project" ]] ; then
    j=$((i+1))
    PROJECT=${!j}
  fi
done

if [[ -z "$PROJECT" ]] ; then
  echo "ERROR: --project <project-id> is required" >&2
  exit 1
fi

if [[ -z "${KUBE_CONTEXT}" ]] ; then
  KUBE_CONTEXT=kubernetes-admin@kubernetes
fi

if [[ -n "$ACCESS_TOKEN_FILE" ]]; then
  ACCESS_TOKEN=$(cat ${ACCESS_TOKEN_FILE})
fi

if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "Generate access token with gcloud:"
  echo "    gcloud auth application-default print-access-token"
  echo "Enter access token:"
  read ACCESS_TOKEN
fi

# Full reference to the setup-robot image.
IMAGE_REFERENCE=$(curl -fsSL -H "Authorization: Bearer ${ACCESS_TOKEN}" \
"https://storage.googleapis.com/${PROJECT}-robot/setup_robot_image_reference.txt") || \
  IMAGE_REFERENCE=""

CRC_VERSION=$(curl -fsSL -H "Authorization: Bearer ${ACCESS_TOKEN}" \
"https://storage.googleapis.com/${PROJECT}-robot/setup_robot_crc_version.txt") || \
  CRC_VERSION=""

if [[ -z "$IMAGE_REFERENCE" ]] ; then
  echo "ERROR: failed to get setup_robot_image_reference.txt from GCS" >&2
  exit 1
fi

# Extract registry from IMAGE_REFERENCE. E.g.:
# IMAGE_REFERENCE = "eu.gcr.io/my-project/setup-robot@sha256:07...5465244d"
# REGISTRY = "eu.gcr.io/my-project"
# REGISTRY_DOMAIN = "eu.gcr.io"
REGISTRY=${IMAGE_REFERENCE%/*}
REGISTRY_DOMAIN=${IMAGE_REFERENCE%%/*}

if [[ "$REGISTRY" != "gcr.io/cloud-robotics-releases" ]] ; then
  # The user has built setup-robot from source and pushed it to a private
  # registry. If so, k8s may not yet have credentials that can pull from a
  # private registry, so use `docker pull` to do this.
  echo "Pulling image from ${REGISTRY_DOMAIN}..."

  echo ${ACCESS_TOKEN} | docker login -u oauth2accesstoken --password-stdin https://${REGISTRY_DOMAIN} || true

  if ! docker pull ${IMAGE_REFERENCE}; then
    docker logout https://${REGISTRY_DOMAIN}
    echo "ERROR: failed to pull setup-robot image" >&2
    exit 1
  fi
  docker logout https://${REGISTRY_DOMAIN}
fi

# Generate TLS certificate if none exists, or if it is in the older v1 format.
# It is used by the robot-master to allow the Kubernetes API server to securly
# connect to webhooks.
if kc get secret robot-master-tls --show-labels 2>/dev/null | grep -q "cert-format=v2"; then
  tls_crt=$(kc get secret robot-master-tls -o=go-template --template='{{index .data "tls.crt"}}')
  tls_key=$(kc get secret robot-master-tls -o=go-template --template='{{index .data "tls.key"}}')
else
  certdir=$(mktemp -d)
  openssl genrsa -out "${certdir}/tls.key" 2048
  openssl req -x509 -new -nodes -key "${certdir}/tls.key" \
    -subj "/CN=robot-master.default.svc" \
    -config <(sed "s/^#\?\s*subjectAltName=.*/subjectAltName=DNS:robot-master.default.svc/" /etc/ssl/openssl.cnf) \
    -days 36500 -reqexts v3_req -extensions v3_ca -out "${certdir}/tls.crt"
  tls_crt=$(openssl base64 -A < ${certdir}/tls.crt)
  tls_key=$(openssl base64 -A < ${certdir}/tls.key)
fi

# The webhook configuration used to be created by a library at runtime. We must
# manually delete it as it wasn't part of a Helm chart.
kc delete validatingwebhookconfiguration \
  validating-webhook-configuration 2>/dev/null || true

# Wait for creation of the default service account.
# https://github.com/kubernetes/kubernetes/issues/66689
i=0
until kc get serviceaccount default &>/dev/null; do
  sleep 1
  i=$((i + 1))
  if ((i >= 60)) ; then
    # Try again, without suppressing stderr this time.
    if ! kc get serviceaccount default >/dev/null; then
      echo "ERROR: 'kubectl get serviceaccount default' failed" >&2
      exit 1
    fi
  fi
done

faketty kubectl --context "${KUBE_CONTEXT}" run setup-robot --restart=Never -it --rm \
  --image=${IMAGE_REFERENCE} \
  --env="ACCESS_TOKEN=${ACCESS_TOKEN}" \
  --env="REGISTRY=${REGISTRY}" \
  --env="TLS_KEY=${tls_key}" \
  --env="TLS_CRT=${tls_crt}" \
  --env="HOST_HOSTNAME=$(hostname)" \
  --env="CRC_VERSION=${CRC_VERSION}" \
  -- "$@"
