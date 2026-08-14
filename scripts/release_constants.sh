#!/usr/bin/env bash

# These readonly values are consumed by the validators that source this file.
# shellcheck disable=SC2034

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    echo 'error: release_constants.sh must be sourced by a release validator' >&2
    exit 64
fi

readonly release_repository_url='https://github.com/revenium/RevvyTach'
readonly release_feed_url="$release_repository_url/releases/latest/download/appcast.xml"
readonly release_bundle_identifier='com.revenium.RevvyTach'
