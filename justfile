set default-list

alias c := check
alias r := run

check:
    prek run --all-files

run:
    zig build run
