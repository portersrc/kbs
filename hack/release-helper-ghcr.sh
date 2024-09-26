#!/bin/bash
set -euo pipefail

#
# This release helper script creates the ghcr packages and associated tags for
# a trustee release.
# This is done by pulling the candidate ghcr packages in "staged-images/",
# tagging them with the appropriate release tags, and then pushing the new
# release tags back to ghcr.
#
# XXX This script is meant to be running "on: release" by a github action
# runner and should rarely require a user to manually run it.
#

declare -g gh_username
declare -g gh_token
declare -g release_candidate_sha
declare -g release_tag

# Output naming convention along with release guide can be found in release-guide.md
declare -a release_pkg_names=(
    "key-broker-service"
    "reference-value-provider-service"
    "attestation-service"
)
declare -A staged_to_release=(
    ["staged-images/kbs"]="key-broker-service"
    ["staged-images/kbs-grpc-as"]="key-broker-service"
    ["staged-images/rvps"]="reference-value-provider-service"
    ["staged-images/coco-as-grpc"]="attestation-service"
    ["staged-images/coco-as-restful"]="attestation-service"
)
declare -A staged_to_release_tag_prefix=(
    ["staged-images/kbs"]="built-in-as-"
    ["staged-images/coco-as-restful"]="rest-"
)

function usage_and_exit() {
    echo
    echo "Usage:"
    echo "  $0  -u github-username  -k github-token  -c release-candidate-sha  -r release-tag"
    echo
    echo "  -u  Your github username. You'll be opening a PR against "
    echo "      confidential-container's trustee/main."
    echo "  -k  A github token with permissions on trustee to write packages"
    echo "      and open PRs."
    echo "  -c  This is the commit sha that's been tested and that you're happy"
    echo "      with. You want to release from this commit sha."
    echo "      Example: dc01f454264fb4350e5f69eba05683a9a1882c41"
    echo "  -r  This is the new version tag that the release will have."
    echo "      Example: v0.8.2"
    echo
    echo "Example usage:"
    echo "    $0 -u \${gh_username} -k \${gh_token} -c dc01f454264fb4350e5f69eba05683a9a1882c41 -r v0.8.2"
    echo
    exit 1
}


function parse_args() {
    while getopts ":u:k:c:r:" opt; do
        case "${opt}" in
            u)
                gh_username=${OPTARG}
                ;;
            k)
                gh_token=${OPTARG}
                ;;
            c)
                release_candidate_sha=${OPTARG}
                ;;
            r)
                release_tag=${OPTARG}
                ;;
            *)
                usage_and_exit
                ;;
        esac
    done
    if [[ ! -v gh_username ]] || [[ ! -v gh_token ]] || [[ ! -v release_candidate_sha ]] || [[ ! -v release_tag ]]; then
        usage_and_exit
    fi
}


function tag_and_push_packages() {
    local ghcr_repo="ghcr.io/confidential-containers"

    echo
    echo "Tagging packages"
    echo "  Release candidate sha: ${release_candidate_sha}"
    echo "  Newly released tag will be: ${release_tag}"
    echo

    echo ${gh_token} | docker login ghcr.io -u ${gh_username} --password-stdin

    for staged_pkg_name in ${!staged_to_release[@]}; do
        release_pkg_name=${staged_to_release[${staged_pkg_name}]}

        # set tag prefix (if needed)
        release_tag_prefix=
        if [[ -v staged_to_release_tag_prefix[${staged_pkg_name}] ]]; then
            release_tag_prefix=${staged_to_release_tag_prefix[${staged_pkg_name}]}
        fi
        release_tag_full=${release_tag_prefix}${release_tag}

        for arch in x86_64 s390x; do
            # pull the staged package
            docker pull ${ghcr_repo}/${staged_pkg_name}:${release_candidate_sha}-${arch}

            # tag it
            docker tag ${ghcr_repo}/${staged_pkg_name}:${release_candidate_sha}-${arch} \
                ${ghcr_repo}/${release_pkg_name}:${release_tag_full}-${arch}

            # push it (i.e. release it)
            docker push ${ghcr_repo}/${release_pkg_name}:${release_tag_full}-${arch}
        done

        # Publish the multi-arch manifest
        docker manifest create ${ghcr_repo}/${release_pkg_name}:${release_tag_full} \
            --amend ${ghcr_repo}/${release_pkg_name}:${release_tag_full}-x86_64 \
            --amend ${ghcr_repo}/${release_pkg_name}:${release_tag_full}-s390x
        docker manifest push ${ghcr_repo}/${release_pkg_name}:${release_tag_full}
    done

    # Publish a latest tag. Note this will be applied to only the non-prefixed
    # packages (e.g. the "built-in-as" kbs package won't have a latest tag).
    for release_pkg_name in ${release_pkg_names[@]}; do
        docker manifest create ${ghcr_repo}/${release_pkg_name}:latest \
            --amend ${ghcr_repo}/${release_pkg_name}:${release_tag}-x86_64 \
            --amend ${ghcr_repo}/${release_pkg_name}:${release_tag}-s390x
        docker manifest push ${ghcr_repo}/${release_pkg_name}:latest
    done

    # Push ITA
    docker pull ${ghcr_repo}/staged-images/kbs-ita-as:${release_candidate_sha}-x86_64
    docker tag ${ghcr_repo}/staged-images/kbs-ita-as:${release_candidate_sha}-x86_64 \
        ${ghcr_repo}/key-broker-service:ita-as-${release_tag}
    docker tag ${ghcr_repo}/staged-images/kbs-ita-as:${release_candidate_sha}-x86_64 \
        ${ghcr_repo}/key-broker-service:ita-as-${release_tag}-x86_64
    docker push ${ghcr_repo}/key-broker-service:ita-as-${release_tag}
    docker push ${ghcr_repo}/key-broker-service:ita-as-${release_tag}-x86_64
}


function main() {
    parse_args "$@"
    tag_and_push_packages
    echo "Success. Exiting..."
}


main "$@"