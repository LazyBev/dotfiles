#!/bin/bash

if [ $(swaync-client -D) = "false" ]; then
	pw-play $HOME/.config/swaync/ding.wav
fi

