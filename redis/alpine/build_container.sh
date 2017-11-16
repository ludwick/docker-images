#!/usr/bin/env bash

set -e

# This is a very simple script to build and push this container.
# It assumes you have docker installed and your gcloud creds to
# push to the container registry are setup right.

typeset version=$(cat version.txt)
typeset tag="gcr.io/glowforge_1/smileisak-redis-fork:4.0.2-$version"
docker build --tag="$tag" .
gcloud docker -- push "$tag"
echo "Pushed build $tag."
