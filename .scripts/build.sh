#!/bin/sh

scheme="Owlse"

while getopts "s:d:" opt; do
    case $opt in
        s) scheme=${OPTARG};;
        d) destinations+=("$OPTARG");;
        #...
    esac
done
shift $((OPTIND -1))

echo "scheme = ${scheme}"
echo "destinations = ${destinations[@]}"

if [ ${#destinations[@]} -eq 0 ]; then
    echo "error: no destinations provided (-d)" >&2
    exit 1
fi

set -o pipefail
xcodebuild -version

for dest in "${destinations[@]}"; do
	echo "Building for destination: $dest"
	xcodebuild build -scheme "$scheme" -destination "$dest" | xcpretty;
    if [ $? -ne 0 ]; then
        exit $?
    fi
done

exit $?
