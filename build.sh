#!/bin/sh

# If a command fails then the deploy stops
set -e

printf "\033[0;32mRebuilding site...\033[0m\n"

# Build the project.
hugo

# Go To Public folder
git add public/

# Commit changes.
msg="rebuilding site $(date)"
if [ -n "$*" ]; then
	msg="$*"
fi
git commit -m "$msg"
