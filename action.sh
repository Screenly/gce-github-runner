#!/usr/bin/env bash

ACTION_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

function usage {
  echo "Usage: ${0} --command=[start|stop] <arguments>"
}

function safety_on {
  set -o errexit -o pipefail -o noclobber -o nounset
}

function safety_off {
  set +o errexit +o pipefail +o noclobber +o nounset
}

source "${ACTION_DIR}/vendor/getopts_long.sh"

arm=
mig=

OPTLIND=1
while getopts_long :h opt \
  arm required_argument \
  mig required_argument \
  help no_argument "" "$@"
do
  case "$opt" in
    arm)
      arm=$OPTLARG
      ;;
    mig)
      mig=$OPTLARG
      ;;
    h|help)
      usage
      exit 0
      ;;
    :)
      printf >&2 '%s: %s\n' "${0##*/}" "$OPTLERR"
      usage
      exit 1
      ;;
  esac
done

set -xeuo pipefail
IFS=$'\t\n'

function start_vm {
  echo "Starting GCE VM ..."

  VM_ID="gce-gh-runner-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"

  echo "The new GCE VM will be ${VM_ID}"

  # GCE VM label values requirements:
  # - can contain only lowercase letters, numeric characters, underscores, and dashes
  # - have a maximum length of 63 characters
  # ref: https://cloud.google.com/compute/docs/labeling-resources#requirements
  #
  # Github's requirements:
  # - username/organization name
  #   - Max length: 39 characters
  #   - All characters must be either a hyphen (-) or alphanumeric
  # - repository name
  #   - Max length: 100 code points
  #   - All code points must be either a hyphen (-), an underscore (_), a period (.),
  #     or an ASCII alphanumeric code point
  # ref: https://github.com/dead-claudia/github-limits
  function truncate_to_label {
    local in="${1}"
    in="${in:0:63}"                              # ensure max length
    in="${in//./_}"                              # replace '.' with '_'
    in=$(tr '[:upper:]' '[:lower:]' <<< "${in}") # convert to lower
    echo -n "${in}"
  }
  gh_repo_owner="$(truncate_to_label "${GITHUB_REPOSITORY_OWNER}")"
  gh_repo="$(truncate_to_label "${GITHUB_REPOSITORY##*/}")"
  gh_run_id="${GITHUB_RUN_ID}"

  gcloud compute instance-groups managed create-instance "$mig" --instance "${VM_ID}" \
    && echo "label=${VM_ID}" >> "$GITHUB_OUTPUT"

  safety_off
  while (( i++ < 60 )); do
    GH_READY=$(gcloud compute instances describe "${VM_ID}" --format='json(labels)' | jq -r .labels.gh_ready)
    if [[ $GH_READY == 1 ]]; then
      break
    fi
    echo "${VM_ID} not ready yet, waiting 5 secs ..."
    sleep 5
  done
  if [[ $GH_READY == 1 ]]; then
    echo "✅ ${VM_ID} ready ..."
  else
    echo "Waited 5 minutes for ${VM_ID}, without luck, deleting ${VM_ID} ..."
    gcloud --quiet compute instances delete "${VM_ID}" --zone="${machine_zone}"
    exit 1
  fi
}

safety_on
start_vm
