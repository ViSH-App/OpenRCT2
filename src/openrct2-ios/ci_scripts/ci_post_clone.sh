#!/bin/sh
# Xcode Cloud: the tools the Native target uses to build the dependencies, assets and engine.
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
# python@3.13: the pixel-font conversion needs fontTools, which requires Python 3.11 or later.
brew install cmake ninja pkgconf python@3.13
cmake --version
ninja --version
python3 --version
