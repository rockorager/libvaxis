#!/bin/sh

printf "\x1b[H"
printf "\x1b[2J"

printf "AAAA\n"
printf "BBBB\n"
printf "CCCC\n"
printf "DDDD\n"
printf "EEEE\n"
printf "FFFF\n"
printf "GGGG\n"
printf "HHHH\n"
sleep 1

printf "\x1b[T"
sleep 3
printf "\x1b[S"
sleep 3
printf "\x1b[2;4r"
printf "\x1b[T"
sleep 3
printf "\x1b[S"
sleep 3
