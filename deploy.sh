#!/bin/bash
# Deploys changes to the master branch of the blog.

# If a command fails then the deploy stops
set -e

printf "\033[0;32mRebuilding site...\033[0m\n"

# Build the project.
hugo --minify --gc

# Go To Public folder
cd public/
git add .

# Commit changes.
msg="rebuilding site $(date)"
if [ -n "$*" ]; then
	msg="$*"
fi
git commit -m "$msg"

# Push source and build repos.
git push origin main
cd -
