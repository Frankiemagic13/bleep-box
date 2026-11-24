#!/bin/bash
# Bleep Box for Mac - builds the app, installs it in /Applications,
# and installs the Stream Deck plugin.
cd "$(dirname "$0")"
clear
echo "=== Bleep Box for Mac ==="
echo

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Bleep Box needs the free Xcode Command Line Tools to build."
  echo "A window opens now. Click Install. When it is finished,"
  echo "double-click this file again."
  xcode-select --install 2>/dev/null
  echo
  read -r -p "Push Return to close."
  exit 1
fi

if ! bash source/mac/build.sh; then
  echo
  echo "The build failed. Copy the text above and send it to Claude."
  read -r -p "Push Return to close."
  exit 1
fi

echo
echo "Installing to /Applications ..."
pkill -x BleepBox 2>/dev/null
sleep 0.5
rm -rf "/Applications/Bleep Box.app"
cp -R "source/mac/build/Bleep Box.app" /Applications/

echo "Installing the Stream Deck plugin ..."
open "streamdeck/com.frankievalletech.bleepbox.streamDeckPlugin"

echo "Opening Bleep Box ..."
open "/Applications/Bleep Box.app"

echo
echo "Done. Next steps:"
echo " 1. Bleep Box asks for the microphone. Click Allow."
echo " 2. In Bleep Box, select your Wave mic."
echo " 3. Wave Link: Create Channel -> Add App -> Bleep Box."
echo " 4. Wave Link: send Bleep Box to the Stream mix. Take the Wave mic out of the Stream mix."
echo " 5. Stream Deck: drag Bleep (Bleep Box category) onto a key."
echo
echo "See 'Mac - READ ME.txt' for all the steps."
read -r -p "Push Return to close."
